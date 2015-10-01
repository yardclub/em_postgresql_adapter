require "bundler/gem_tasks"
require 'rake/testtask'

Rake::TestTask.new do |t|
  $LOAD_PATH.unshift(File.join(__FILE__, '../test'))
  t.test_files = FileList['test/test_*.rb']
  t.libs << 'test'
end
