module JeCloud
class ServerSession

  extend Forwardable

  def_delegators :ssh, :sudo!, :sudo_print!, :exec!

  def initialize application, server, user_name, ec2_ssh_key_file
    @application = application
    @server = server
    @user_name = user_name
    @ec2_ssh_key_file = ec2_ssh_key_file
  end

  def ssh
    @ssh ||= connect_to_ssh
  end

  def sftp
    @sftp ||= Net::SFTP::Session.new(ssh).tap { |sftp| sftp.loop { sftp.opening? } }
  end

  def close!
    @ssh.close if @ssh
  end

private

  def connect_to_ssh
    $log.debug "Connecting via SSH to #{@user_name}@#{@server.public_ip}"
    Net::SSH.start(@server.public_ip, @user_name, :keys => [@ec2_ssh_key_file])
  end

end
end
