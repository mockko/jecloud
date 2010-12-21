module JeCloud
class CLI

  def status!
    application.status!
  end

  def deploy! args
    git_ref = args.first || 'HEAD'
    application.deploy! git_ref
  end

  def terminate!
    application.terminate!
  end

  def roll_forward!
    application.roll_forward!
  end

private

  def application
    JeCloud::Application.new(Dir.pwd)
  end

end
end
