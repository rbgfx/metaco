# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/extensiontask"
require "rake/testtask"
require "rbconfig"

Rake::ExtensionTask.new("metaco") do |ext|
  ext.lib_dir = "lib/metaco"
end

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/test_*.rb"]
end

desc "Run native regression tests with GPU readback and fault injection"
task :test_native do
  next unless RUBY_PLATFORM.include?("darwin")

  build_dir = File.expand_path("tmp/native/#{RUBY_PLATFORM}/#{RUBY_VERSION}", __dir__)
  mkdir_p build_dir
  Dir.chdir(build_dir) do
    ruby File.expand_path("test/native/extconf.rb", __dir__)
    sh RbConfig::CONFIG.fetch("MAKE", "make")
  end
  ruby "-I#{build_dir}", "test/native/regressions.rb"
end

task test: [:compile, :test_native]
task default: :test
task verify: :test
