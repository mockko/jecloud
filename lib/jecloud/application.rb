module JeCloud
class Application

  MAX_REPEAT_DELAY = 10

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
        puts sprintf(format, server.instance_id, server.public_ip)
      end
      puts '=' * empty.size
      puts
    end
  end

  def apply! cloud_config_file
    update_config do
      @config.cloud = YAML.load(File.read(cloud_config_file))
    end
    add_server! if @config.servers.empty?
    roll_forward!
  end

  def deploy! git_ref
    rev = `git rev-parse #{git_ref}`.strip
    die!("Invalid Git ref: #{git_ref}") if rev.size != 40

    $log.info "Deploying revision #{rev}"
    server = @config.servers.first || add_server!
    server.deployment = { 'version' => rev }

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

    @config.servers.each do |server|
      server_session = ServerSession.new(self, server, @config.cloud.server_user_name, @ec2_ssh_key_file)
      catch :failed do
        session.action "#{server.uuid}-initial-setup", :unless => server.instance_id? do
          instance_type = @config.cloud.ec2_instance_type
          die!("ec2_instance_type not specified") if instance_type.nil?

          ami = @config.cloud.ec2_ami
          die!("ec2_ami not specified") if ami.nil?

          make_key!

          $log.debug "Starting an instance of type #{instance_type} with AMI #{ami}"
          r = @ec2.run_instances :image_id => ami, :key_name => @ec2_ssh_key_name, :instance_type => instance_type, :client_token => server.uuid
          puts r.to_yaml
          instance_res = ((r.instancesSet || {}).item || [])[0]

          server.instance_id = instance_res.instanceId
          server.public_ip = instance_res.ipAddress
          $log.info "Successfully started an instance with ID #{server.instance_id}"
        end
        session.action "#{server.uuid}-obtain-ip", :unless => server.public_ip? do
          r = @ec2.describe_instances
          puts r.to_yaml
          instance = describe_instances_flat.find { |i| i.instanceId == server.instance_id }
          unless (instance.ipAddress || '').empty?
            $log.info "Instance with ID #{server.instance_id} has been assigned IP #{server.public_ip}"
            server.public_ip = instance.ipAddress
          end
          raise ExpectedDelay, "No IP address assigned yet"
        end

        session.check "#{server.uuid}-sudo-test" do
          x = server_session.sudo!("echo ok").strip
          if x == 'ok'
            $log.debug "sudo test ok"
          else
            raise UnexpectedExternalProblem, "sudo does not work on #{server.public_ip}"
          end
        end

        jecloud_installed = session.check("#{server.uuid}-is-jecloud-up-to-date") do
          jecloud_version = server_session.exec!("jecloud print-version || echo 'NONE'").strip
          (jecloud_version =~ /^\d+\.\d+(?:\.\d+(?:\.\d+)?)?$/ && jecloud_version.pad_numbers >= JeCloud::VERSION.pad_numbers).tap do |is_good_enough|
            $log.debug "JeCloud version on the server: #{jecloud_version} (#{is_good_enough ? 'Good to go!' : 'Need to (re)install JeCloud.'})"
          end
        end

        session.action "#{server.uuid}-install-jecloud", :unless => jecloud_installed do
          yum_packages = %w/gcc gcc-c++ openssl openssl-devel ruby-devel rubygems git/

          apt_packages = %w/build-essential ruby rubygems ruby1.8-dev libzlib-ruby libyaml-ruby libdrb-ruby liberb-ruby rdoc zlib1g-dev libopenssl-ruby upstart/  # TODO: revise this set

          case @config.cloud.package_manager
          when 'yum'
            $log.debug "Installing yum packages: #{yum_packages.join(' ')}"
            server_session.sudo_print!("yum install -y #{yum_packages.join(' ')}")
            $log.info "Installed yum packages: #{yum_packages.join(' ')}"
          when 'apt'
            $log.debug "Installing apt packages: #{apt_packages.join(' ')}"
            server_session.sudo_print!("apt-get install #{apt_packages.join(' ')}")
            $log.info "Installed apt packages: #{apt_packages.join(' ')}"
          else
            throw "Unsupported package manager #{@config.cloud.package_manager}"
          end

          $log.debug "Rebuilding JeCloud locally"
          puts `rake build`
          raise UnexpectedExternalProblem, "JeCloud build failed" unless $?.success?

          remote_path = "/tmp/#{File.basename(GEM_FILE)}"
          $log.debug "Uploading JeCloud gem into #{server.public_ip}:#{remote_path}"
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
            $log.info "Installed JeCloud on #{server.public_ip}"
          else
            puts jecloud_version
            raise UnexpectedExternalProblem, "Installation of JeCloud failed on #{server.public_ip}"
          end
        end

        session.action "#{server.uuid}-start-deployment", :if => server.deployment? do
          # pretend that it succeeded
          server.deployment = nil
        end
      end
      server_session.close!
    end
  end

  def upload_repository_ssh_key! key_file
    key = File.read(key_file)
    raise "file #{key_file} does not contain a valid SSH private key" unless key =~ /BEGIN [RD]SA PRIVATE KEY/ && key =~ /END [RD]SA PRIVATE KEY/
    update_config do
      @config.repository_ssh_key = key
    end
  end

private

  def add_server!
    update_config do
      server = { 'status' => 'creating', 'instance_id' => nil }
      @config.servers << server
      server
    end
  end

  def read_config
    begin
      Hashie::Mash.new(YAML.load(AWS::S3::S3Object.value('state.json', config_bucket.name)))
    rescue AWS::S3::NoSuchKey
      Hashie::Mash.new
    end.tap do |config|
      config.servers ||= []
      config.servers.each do |server|
        server.uuid ||= `uuidgen`.strip
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
