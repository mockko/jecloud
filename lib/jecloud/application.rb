module JeCloud
class Application

  MAX_REPEAT_DELAY = 40

  class ExpectedDelay < Exception
  end

  class UnexpectedExternalProblem < Exception
  end

  def initialize access_file
    @access_config = AccessConfig.read(access_file)

    @cache_dir = "/tmp/jecloud"
    FileUtils.mkdir_p(@cache_dir)

    @ec2 = @access_config.establish_connection!

    @ec2_ssh_key_name = "id_#{app_name}"
    @ec2_ssh_key_file = File.join(@cache_dir, @ec2_ssh_key_name)

    @config = read_config
  rescue Errno::ENOENT => e
    $stderr.puts e.message
    exit 1
  end

  def app_name; @access_config.app_name; end

  def config_bucket_name
    @config_bucket_name ||= "jecloud-#{app_name}"
  end

  def config_bucket
    @config_bucket ||= find_or_create_config_bucket
  end

  def find_or_create_config_bucket
    begin
      bucket = AWS::S3::Bucket.find(config_bucket_name)
      $log.info "Using existing config bucket #{config_bucket_name}"
    rescue AWS::S3::NoSuchBucket
      bucket = AWS::S3::Bucket.create(config_bucket_name)
      $log.warn "Created new config bucket #{config_bucket_name}"
    end
    return bucket
  end

  def status!
    puts
    puts "GLOBAL STATE ON S3:"
    puts
    puts @config.to_hash.to_yaml

    instances = describe_instances_flat
    unless instances.empty?
      format = '%-10s  %-15s  %-10s %-12s  %-12s  '
      empty  = sprintf(format, "", "", "", "", "")

      puts
      puts
      puts "AMAZON EC2 INSTANCES:"
      puts
      puts '=' * empty.size
      puts sprintf(format, "Instance", "IP", "Type", "AMI", "State")
      puts '-' * empty.size
      instances.each do |server|
        puts sprintf(format, server.instanceId, server.ipAddress, server.instanceType, server.imageId, server.instanceState.andand.name || 'unknown')
      end
      puts '=' * empty.size
    else
      puts
      puts "NO AMAZON EC2 INSTANCES"
    end

    if (@config.servers || []).empty?
      puts
      puts "NO SERVERS MANAGED BY JeCLOUD."
    else
      puts
      puts
      puts "SERVERS MANAGED BY JeCLOUD:"
      puts

      format = '%-10s  %-15s  '
      empty  = sprintf(format, "", "")

      puts '=' * empty.size
      puts sprintf(format, "Instance", "IP")
      puts '-' * empty.size
      @config.servers.each do |server|
        puts sprintf(format, server['instance_id'], server['public_ip'])
      end
      puts '=' * empty.size
      puts
    end
  end

  def apply! cloud_config_file
    update_config do
      @config.cloud = YAML.load(File.read(cloud_config_file))
    end
    roll_forward!
  end

  def deploy! git_ref
    if git_ref =~ /^[0-9a-f]{40}$/
      rev = git_ref
    else
      rev = `git rev-parse #{git_ref}`.strip
      die!("Invalid Git ref: #{git_ref}") if rev.size != 40
    end

    $log.info "Deploying revision #{rev}"

    update_config do
      @config.cooking_version = {
        'id' => rev,
        'deployment_requested_at' => Time.now.to_i,
        'state' => 'downloading'
      }
    end

    roll_forward!
  end

  def terminate!
    describe_instances_flat.each do |instance|
      ip, instance_id = instance['ipAddress'], instance['instanceId']

      $log.debug "Terminating instance #{instance_id} (#{ip})..."
      @ec2.terminate_instances :instance_id => [instance_id]
      $log.info "Terminated instance #{instance_id} (#{ip})"
    end
  end

  def roll_forward!
    1.times do
      cont = true
      next_attempt = nil
      while cont
        update_config do
          Session.new(@config.failures).tap do |session|
            roll_forward_step! session
            next_attempt, cont = session.next_attempt, session.any_actions_executed?
          end
        end
      end
      if next_attempt
        delay = [0, next_attempt - Time.now.to_i].max
        if delay > MAX_REPEAT_DELAY
          $log.info "Next attempt delay is #{delay} sec (which is > #{MAX_REPEAT_DELAY} sec limit), quitting"
        else
          $log.info "Sleeping for #{delay} sec"
          sleep delay
          retry
        end
      end
    end
  end

  def roll_forward_step! session
    $log.debug "Roll forward running"

    session.action "create-ssh-key-pair", :unless => @config.ec2_ssh_key? do
      raise "unexpected!"
      $log.debug "Deleting key pair @ec2_ssh_key_name"
      @ec2.delete_keypair(:key_name => @ec2_ssh_key_name)

      $log.debug "Creating key pair @ec2_ssh_key_name"
      result = @ec2.create_keypair(:key_name => @ec2_ssh_key_name)

      @config.ec2_ssh_key = result.keyMaterial
    end

    unless File.file?(@ec2_ssh_key_file)
      File.open(@ec2_ssh_key_file, 'w') { |f| f.write @config.ec2_ssh_key }
      File.chmod(0600, @ec2_ssh_key_file)
    end

    # no index_by in Ruby :-(
    instances_by_id = {}
    describe_instances_flat.each { |i| instances_by_id[i.instanceId] = i }

    while @config.servers.select { |s| s.sentence == 'live' }.size < @config.cloud.server_count
      @config.servers << { 'uuid' => `uuidgen`.strip, 'instance_id' => nil, 'sentence' => 'live' }
      session.changed!
      $log.info "Will start a new server to increase server count"
    end
    while @config.servers.select { |s| s.sentence == 'live' }.size > @config.cloud.server_count
      server = @config.servers.select { |s| s.sentence == 'live' }.last
      server.sentence = 'die'
      session.changed!
      $log.info "Will terminate server #{server['instance_id']} (#{server['public_ip']}) to decrease server count"
    end

    @config.servers.each do |server|
      server_session = ServerSession.new(self, server, @config.cloud.server_user_name, @ec2_ssh_key_file)
      catch :failed do
        instance = if server['instance_id'] then instances_by_id[server['instance_id']] else nil end

        server['instance_state'] = instance.andand.instanceState.andand.name || 'does-not-exist'

        if ['terminated', 'does-not-exist'].include? server['instance_state']
          $log.warn "Server #{server['uuid']} is dead (EC2 instance #{server['instance_state']}) -- will remove from the state file"
          server.sentence = 'dead'
          session.changed!
        end

        # keep IP address in sync, need it to execute both 'die' and 'live' sentences
        if server['public_ip'] != instance.andand.ipAddress
          old_ip, server['public_ip'] = server['public_ip'], instance.andand.ipAddress

          if server['public_ip']
            $log.info "Instance with ID #{server['instance_id']} has been assigned IP #{server['public_ip']}"
          else
            $log.info "Instance with ID #{server['instance_id']} has lost its prior IP #{old_ip}"
          end
        end

        case server.sentence
        when 'dead'
          throw :failed  # do nothing, will clean up soon
        when 'die'
          $log.debug "Terminating instance #{server['instance_id']} (#{server['public_ip']})..."
          @ec2.terminate_instances :instance_id => [server['instance_id']]
          $log.info "Terminated instance #{server['instance_id']} (#{server['public_ip']})"
          throw :failed
        end

        # the rest is only for alive servers

        session.action "#{server['uuid']}-initial-setup", :if => server['instance_id'].nil? do
          instance_type = @config.cloud.ec2_instance_type
          die!("ec2_instance_type not specified") if instance_type.nil?

          ami = @config.cloud.ec2_ami
          die!("ec2_ami not specified") if ami.nil?

          $log.debug "Starting an instance of type #{instance_type} with AMI #{ami}"
          r = @ec2.run_instances :image_id => ami, :key_name => @ec2_ssh_key_name, :instance_type => instance_type, :client_token => server['uuid']
          puts r.to_yaml
          instance_res = r.instancesSet.item[0]
          puts instance_res.to_yaml

          server['instance_id'] = instance_res.instanceId
          server['public_ip'] = instance_res.ipAddress
          puts server.to_yaml
          $log.info "Successfully started an instance with ID #{server['instance_id']} / #{instance_res.instanceId}"
        end

        session.check "#{server['uuid']}-running-state-and-ip-required" do
          case server['instance_state']
          when 'running'
            if server['public_ip'].nil?
              raise ExpectedDelay, "No IP address assigned yet to server #{server['uuid']} (#{server['instance_id']})"
            end
          else
            raise ExpectedDelay, "Server state is '#{server['instance_state']}', waiting for 'running' state -- server #{server['uuid']} (#{server['instance_id']})"
          end
        end

        session.check "#{server['uuid']}-sudo-test" do
          x = server_session.sudo!("echo ok").strip
          if x == 'ok'
            $log.debug "sudo test ok"
          else
            raise UnexpectedExternalProblem, "sudo does not work on #{server['public_ip']}"
          end
        end

        jecloud_installed = session.check("#{server['uuid']}-is-jecloud-up-to-date") do
          jecloud_version = server_session.exec!("jecloud print-version || echo 'NONE'").strip
          (jecloud_version =~ /^\d+\.\d+(?:\.\d+(?:\.\d+)?)?$/ && jecloud_version.pad_numbers >= JeCloud::VERSION.pad_numbers).tap do |is_good_enough|
            $log.debug "JeCloud version on the server: #{jecloud_version} (#{is_good_enough ? 'Good to go!' : 'Need to (re)install JeCloud.'})"
          end
        end

        session.action "#{server['uuid']}-install-jecloud", :unless => jecloud_installed do
          yum_packages = %w/gcc gcc-c++ openssl openssl-devel ruby-devel rubygems git/
          apt_packages = %w/build-essential ruby ruby1.8-dev libzlib-ruby libyaml-ruby libdrb-ruby liberb-ruby rdoc zlib1g-dev libopenssl-ruby upstart/  # TODO: revise this set

          case @config.cloud.package_manager
          when 'yum'
            $log.debug "Installing yum packages: #{yum_packages.join(' ')}"
            server_session.sudo_print!("yum install -y #{yum_packages.join(' ')}")
            $log.info "Installed yum packages: #{yum_packages.join(' ')}"
          when 'apt'
            $log.debug "Installing apt packages: #{apt_packages.join(' ')}"
            server_session.sudo_print!("apt-get install -y #{apt_packages.join(' ')}")
            $log.info "Installed apt packages: #{apt_packages.join(' ')}"

            # fix broken rubygems install on Debian, see:
            # http://blog.costan.us/2010/03/quick-way-out-of-ubuntus-rubygems-jail.html

            # alas, did not work, and we don't want fucked-up debian rubygems anyway
            # server_session.sudo_print!(%q!sh -c 'sudo echo "PATH=/var/lib/gems/1.8/bin:$PATH" > /etc/profile.d/rubygems1.8.sh'!)

            server_session.sudo_print!(%q!sh -c 'which node || {
              curl -O -L http://rubyforge.org/frs/download.php/70696/rubygems-1.3.7.tgz
              tar xzf rubygems-1.3.7.tgz
              cd rubygems-1.3.7
              ruby setup.rb --no-format-executable
              cd ..
              rm rubygems-1.3.7.tgz
              rm -rf rubygems-1.3.7
            }'!)
          else
            throw "Unsupported package manager #{@config.cloud.package_manager}"
          end

          $log.debug "Rebuilding JeCloud locally"
          puts `rake build`
          raise UnexpectedExternalProblem, "JeCloud build failed" unless $?.success?

          remote_path = "/tmp/#{File.basename(GEM_FILE)}"
          $log.debug "Uploading JeCloud gem into #{server['public_ip']}:#{remote_path}"
          server_session.sftp.file.open(remote_path, 'w') do |of|
            of.write(File.read(GEM_FILE))
          end
          server_session.sftp.loop

          $log.debug "Uninstalling old JeCloud version if any"
          server_session.sudo_print!("gem uninstall --executables jecloud")

          $log.debug "Installing JeCloud gem"
          server_session.sudo_print!("gem install --no-rdoc --no-ri #{remote_path}")

          jecloud_version = server_session.exec!("jecloud print-version || echo 'NONE'").strip
          if jecloud_version == JeCloud::VERSION
            $log.info "Installed JeCloud on #{server['public_ip']}"
          else
            puts jecloud_version
            raise UnexpectedExternalProblem, "Installation of JeCloud failed on #{server['public_ip']}"
          end
        end
      end
      server_session.close!
    end

    @config.servers.reject! { |server| server.sentence == 'dead' }
  end

  def upload_repository_ssh_key! key_file
    key = File.read(key_file)
    raise "file #{key_file} does not contain a valid SSH private key" unless key =~ /BEGIN [RD]SA PRIVATE KEY/ && key =~ /END [RD]SA PRIVATE KEY/
    update_config do
      @config.repository_ssh_key = key
    end
  end

private

  def read_config
    begin
      Hashie::Mash.new(YAML.load(AWS::S3::S3Object.value('state.json', config_bucket.name)))
    rescue AWS::S3::NoSuchKey
      Hashie::Mash.new
    end.tap do |config|
      config.servers ||= []
      config.servers.each do |server|
        server['uuid'] ||= `uuidgen`.strip
      end
      config.failures!
    end
  end

  def update_config
    result = yield
    AWS::S3::S3Object.store 'state.json', YAML.dump(@config.to_hash), config_bucket.name
    puts @config.to_hash.to_yaml
    return result
  end

  def die! message
    $stderr.puts message
    exit 1
  end

private

  def describe_instances_flat
    ans = @ec2.describe_instances
    if ans.reservationSet
      ans.reservationSet.item.collect { |i| i.instancesSet.item }.flatten
    else
      []
    end
  end

end
end
