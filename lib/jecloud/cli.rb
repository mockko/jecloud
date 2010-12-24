module JeCloud
class CLI

  def method_missing id, *args, &block
    application.send(id, *args, &block)
  end

private

  def application
    JeCloud::Application.new(find_access_file)
  end

  def find_access_file
    each_parent_directory_of(Dir.pwd) do |dir|
      possible_config_file = File.join(dir, 'cloud-access.yml')
      return possible_config_file if File.file? possible_config_file

      possible_config_file = File.join(dir, 'cloud-access.yml.example')
      raise "Please copy cloud-access.yml.example into cloud-access.yml and fill in the keys." if File.file? possible_config_file
    end

    raise "Cannot find cloud-access.yml. Please run from a project directory, or use -A option to specify a location. See jecloud --help."
  end

  def each_parent_directory_of path
    catch :stop do
      prev_directory, directory = nil, path
      while directory != prev_directory
        yield directory

        prev_directory, directory = directory, File.dirname(directory)
      end
    end
  end

end
end
