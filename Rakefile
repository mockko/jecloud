require 'rubygems'
require 'bundler'
begin
  Bundler.setup(:default, :development)
rescue Bundler::BundlerError => e
  $stderr.puts e.message
  $stderr.puts "Run `bundle install` to install missing gems"
  exit e.status_code
end
require 'rake'

require 'jeweler'
Jeweler::Tasks.new do |gem|
  # gem is a Gem::Specification... see http://docs.rubygems.org/read/chapter/20 for more options
  gem.name = "jecloud"
  gem.homepage = "http://github.com/andreyvit/jecloud"
  gem.license = "MIT"
  gem.summary = %Q{JeCloud: open-source cloud stack for node.js}
  gem.description = %Q{
    JeCloud aims to provide an all-inclusive open-source cloud stack, similar to Google App Engine, Heroku
    etc. Initially, JeCloud only supports EC2, though more cloud providers (Rackspace Cloud, Linode) will be
    supported in the future (contributors welcome).
  }
  gem.email = "andreyvit@gmail.com"
  gem.authors = ["Andrey Tarantsov"]
  # Include your dependencies below. Runtime dependencies are required when using your gem,
  # and development dependencies are only needed for development (ie running rake tasks, tests, etc)
  #  gem.add_runtime_dependency 'jabber4r', '> 0.1'
  #  gem.add_development_dependency 'rspec', '> 1.2.3'
end
Jeweler::RubygemsDotOrgTasks.new

require 'rspec/core'
require 'rspec/core/rake_task'
RSpec::Core::RakeTask.new(:spec) do |spec|
  spec.pattern = FileList['spec/**/*_spec.rb']
end

RSpec::Core::RakeTask.new(:rcov) do |spec|
  spec.pattern = 'spec/**/*_spec.rb'
  spec.rcov = true
end

require 'cucumber/rake/task'
Cucumber::Rake::Task.new(:features)

task :default => :spec

require 'rake/rdoctask'
Rake::RDocTask.new do |rdoc|
  version = File.exist?('VERSION') ? File.read('VERSION') : ""

  rdoc.rdoc_dir = 'rdoc'
  rdoc.title = "jecloud #{version}"
  rdoc.rdoc_files.include('README*')
  rdoc.rdoc_files.include('lib/**/*.rb')
end

desc "Write binaries to /usr/local/bin that invoke a development version"
task :link do
  Dir[File.join(File.expand_path(File.dirname(__FILE__)), "bin/*")].each do |binary|
    target = File.join("/usr/local/bin", File.basename(binary))
    puts "#{target} -> #{binary}"

    stub = <<-EOS.gsub(/^ {6}/, '')
      #! /usr/bin/env ruby
      require 'rubygems'
      load '#{binary}'
    EOS

    FileUtils.rm_rf target
    File.open(target, 'w') { |f| f.write stub }
    File.chmod(0755, target)
  end
end
