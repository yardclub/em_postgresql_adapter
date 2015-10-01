require 'delegate'
require 'bundler/setup'
Bundler.setup

require 'em_postgresql_adapter'
require 'minitest/autorun'

def config
  { dbname: 'em_test' }
end
