
require 'yaml'
require 'fileutils'
require 'logger'

require 'AWS'               # amazon-ec2
require 'aws/s3'            # aws-s3
require 'net/ssh'           # net-ssh
require 'net/sftp'          # net-sftp
require 'hashie'            # hashie gem

require 'jecloud/application'
require 'jecloud/cli'

module JeCloud
  VERSION = File.read(File.join(File.dirname(__FILE__), '..', 'VERSION'))
  GEM_FILE = File.join(File.dirname(__FILE__), '..', 'pkg', "jecloud-#{VERSION}.gem")
end

class String
  def pad_numbers
    gsub(/\d+/) { |num| sprintf("%04d", num.to_i) }
  end
end

class Net::SSH::Connection::Session
  def exec_with_pty(command, &block)
    open_channel do |channel|
      channel.request_pty do |ch, success|
        raise "could not request a channel" unless success

        channel.exec(command) do |ch, success|
          raise "could not execute command: #{command.inspect}" unless success

          channel.on_data do |ch2, data|
            if block
              block.call(ch2, :stdout, data)
            else
              $stdout.print(data)
            end
          end

          channel.on_extended_data do |ch2, type, data|
            if block
              block.call(ch2, :stderr, data)
            else
              $stderr.print(data)
            end
          end
        end
      end
    end
  end

  def exec_with_pty!(command, &block)
    block ||= Proc.new do |ch, type, data|
      ch[:result] ||= ""
      ch[:result] << data
    end

    channel = exec_with_pty(command, &block)
    channel.wait

    return channel[:result]
  end

  def sudo!(command)
    exec_with_pty!("sudo -n #{command}")
  end

  def sudo_print!(command)
    exec_with_pty("sudo -n #{command}").wait
  end
end

$log = Logger.new($stderr)
