module JeCloud
class AccessConfig

  attr_reader :app_name
  attr_reader :aws_access_key_id
  attr_reader :aws_secret_access_key

  def initialize hash
    @app_name              = (hash['app_name']                 || '').freeze
    @aws_access_key_id     = (hash['aws']['access_key_id']     || '').freeze
    @aws_secret_access_key = (hash['aws']['secret_access_key'] || '').freeze

    raise "AWS access key id missing from cloud-access.yml"     if @aws_access_key_id.size < 5
    raise "AWS secret access key missing from cloud-access.yml" if @aws_secret_access_key.size < 5
  end

  def establish_connection!
    AWS::S3::Base.establish_connection!(
      :access_key_id     => @aws_access_key_id,
      :secret_access_key => @aws_secret_access_key
    )

    ec2 = AWS::EC2::Base.new(
      :access_key_id     => @aws_access_key_id,
      :secret_access_key => @aws_secret_access_key
    )

    return ec2
  end

  def self.read file
    AccessConfig.new(YAML.load(File.read(file)))
  end

end
end
