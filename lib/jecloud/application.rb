module JeCloud
class Application

  attr_reader :app_name

  def initialize config_dir
    @config_dir = config_dir

    @cloud_config = Hashie::Mash.new(YAML.load(File.read(File.join(@config_dir, 'cloud.yml'))))
    @app_name = (@cloud_config.app_name || '').strip
    die!("Required key missing in cloud.yml: app_name") if @app_name.empty?

    @keys_config  = Hashie::Mash.new(YAML.load(File.read(File.join(@config_dir, 'keys.yml'))))

    @deployment_key_priv = File.join(@config_dir, 'id_deployment')

    File.read(@deployment_key_priv)

    AWS::S3::Base.establish_connection!(
      :access_key_id     => @keys_config['aws']['access_key_id'],
      :secret_access_key => @keys_config['aws']['secret_access_key']
    )

    @ec2 = AWS::EC2::Base.new(
      :access_key_id     => @keys_config['aws']['access_key_id'],
      :secret_access_key => @keys_config['aws']['secret_access_key']
    )

    @config_bucket_name = "jecloud-#{app_name}"
    begin
      @config_bucket = AWS::S3::Bucket.find(@config_bucket_name)
      $log.info "Using existing config bucket #{@config_bucket_name}"
    rescue AWS::S3::NoSuchBucket
      @config_bucket = AWS::S3::Bucket.create(@config_bucket_name)
      $log.warn "Created new config bucket #{@config_bucket_name}"
    end

    @ec2_ssh_key_name = "id_#{app_name}"
    @ec2_ssh_key_file = File.join(@config_dir, "id_#{app_name}")

    @config = read_config
  rescue Errno::ENOENT => e
    $stderr.puts e.message
    exit 1
  end

  def make_key!
    unless File.file? @ec2_ssh_key_file
      log 'delete_keypair', @ec2_ssh_key_name
      @ec2.delete_keypair(:key_name => @ec2_ssh_key_name)

      log 'create_keypair', @ec2_ssh_key_name
      result = @ec2.create_keypair(:key_name => @ec2_ssh_key_name)
      puts "Fingerprint: #{result.keyFingerprint}"

      File.open(@ec2_ssh_key_file, 'w') { |f| f.write result.keyMaterial }
      File.chmod(0600, @ec2_ssh_key_file)
      log 'saved', @ec2_ssh_key_file
    end
  end

  def status!
    if (@config.servers || []).empty?
      puts "No servers active, the cloud is down."

      ans = @ec2.describe_instances
      if ans.reservationSet
        puts "Please check that none of the following instances are lost:"
        puts ans.reservationSet.item.collect { |i| i.instancesSet.item }.flatten.to_yaml
      else
        puts "No EC2 instances either."
      end
    else
      @config.servers.each do |server|
        puts "Server!"
      end
    end
    puts
    puts "Current global config:"
    puts
    puts @config.to_hash.to_yaml
  end

  def deploy! git_ref
    rev = `git rev-parse #{git_ref}`.strip
    die!("Invalid Git ref: #{git_ref}") if rev.size != 40

    $log.info "Deploying revision #{rev}"
    server = @config.servers.first || add_server!
    server.deployment = { 'version' => rev }

    roll_forward
  end

  def roll_forward!
    loop do
      update_config do
        return unless roll_forward_step!
      end
    end
  end

  def roll_forward_step!
    $log.debug "Roll forward running"
    @config.servers.each do |server|
      unless server.instance_id?
        instance_type = @cloud_config.ec2_instance_type
        die!("ec2_instance_type not specified") if instance_type.nil?

        ami = @cloud_config.ec2_ami
        die!("ec2_ami not specified") if ami.nil?

        make_key!

        $log.debug "Starting an instance of type #{instance_type} with AMI #{ami}"
        r = @ec2.run_instances :image_id => ami, :key_name => @ec2_ssh_key_name, :instance_type => instance_type
        puts r.to_yaml
        instance_res = ((r.instancesSet || {}).item || [])[0]

        server.instance_id = instance_res.instanceId
        server.public_ip = instance_res.ipAddress
        $log.info "Successfully started an instance with ID #{server.instance_id}"
        return true
      end
      unless server.public_ip?
        r = @ec2.describe_instances
        puts r.to_yaml
        instance = (r.reservationSet.item.collect { |i| i.instancesSet.item } || []).flatten.find { |i| i.instanceId == server.instance_id }
        unless (instance.ipAddress || '').empty?
          $log.info "Instance with ID #{server.instance_id} has been assigned IP #{server.public_ip}"
          server.public_ip = instance.ipAddress
          return true
        end
        next
      end

      jecloud_installed = false
      $log.debug "Connecting via SSH to ec2-user@#{server.public_ip}"
      begin
        Net::SSH.start(server.public_ip, 'ec2-user', :keys => [@ec2_ssh_key_file]) do |ssh|
          $log.debug "SSH connected ok!"

          # ch.request_pty do |ch, success|
          #   raise "could not start a pseudo-tty" unless success
          #
          #   # full EC2 environment
          #   ###ch.env 'key', 'value'
          #   ###...
          #
          #   ch.exec 'sudo echo Hello 1337' do |ch, success|
          #     raise "could not exec against a pseudo-tty" unless success
          #   end
          # end

          x = ssh.sudo!("echo ok").strip
          if x == 'ok'
            $log.debug "sudo test ok"
          else
            $log.error "sudo does not work on #{server.public_ip}"
            next
          end

          jecloud_version = ssh.exec!("jecloud print-version || echo 'NONE'").strip
          $log.debug "JeCloud version on the server: #{jecloud_version}"
          if jecloud_version =~ /^\d+\.\d+(?:\.\d+(?:\.\d+)?)?$/
            if jecloud_version.pad_numbers >= JeCloud::VERSION.pad_numbers
              $log.debug "JeCloud installed on the server is good enough."
              jecloud_installed = true
            end
          end

          unless jecloud_installed
            yum_packages = %w/gcc gcc-c++ openssl openssl-devel ruby-devel rubygems git/

            $log.debug "Installing yum packages: #{yum_packages.join(' ')}"
            ssh.sudo_print!("yum install -y #{yum_packages.join(' ')}")
            $log.info "Installed yum packages: #{yum_packages.join(' ')}"

            sftp = Net::SFTP::Session.new(ssh)
            sftp.loop { sftp.opening? }

            $log.debug "Rebuilding JeCloud locally"
            puts `rake build`

            remote_path = "/tmp/#{File.basename(GEM_FILE)}"
            $log.debug "Uploading JeCloud gem into #{server.public_ip}:#{remote_path}"
            sftp.file.open(remote_path, 'w') do |of|
              of.write(File.read(GEM_FILE))
            end
            sftp.loop

            $log.debug "Uninstalling old JeCloud version if any"
            ssh.sudo_print!("gem uninstall --executables jecloud")

            $log.debug "Installing JeCloud gem"
            ssh.sudo_print!("gem install --no-rdoc --no-ri #{remote_path}")

            jecloud_version = ssh.exec!("jecloud print-version || echo 'NONE'").strip
            if jecloud_version == JeCloud::VERSION
              $log.info "Installed JeCloud on #{server.public_ip}"
              return true
            else
              puts jecloud_version
              $log.error "Installation of JeCloud failed on #{server.public_ip}"
              # TODO: back off next time
              next
            end
          end

          # deployment requested?
          if server.deployment?
            # pretend that it succeeded
            server.deployment = nil
            return true
          end
        end
      rescue Errno::ECONNREFUSED => e
        puts "Server not ready yet."
        next
      end
    end
    return false
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
    Hashie::Mash.new(YAML.load(AWS::S3::S3Object.value('state.json', @config_bucket_name)))
  rescue AWS::S3::NoSuchKey
    Hashie::Mash.new.tap do |config|
      config.servers = []
    end
  end

  def update_config
    @config = read_config
    result = yield
    AWS::S3::S3Object.store 'state.json', YAML.dump(@config.to_hash), @config_bucket_name
    return result
  end

  def die! message
    $stderr.puts message
    exit 1
  end

end
end
