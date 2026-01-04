# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/extensiontask"
require "rake/testtask"

Rake::ExtensionTask.new("metaco") do |ext|
  ext.lib_dir = "lib/metaco"
end

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/test_*.rb"]
end

task test: :compile
task default: :test
