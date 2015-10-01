require 'delegate'
require 'active_record/connection_adapters/em_postgresql_adapter'

ActiveRecord::Base.default_connection_handler = ActiveRecord::ConnectionAdapters::SimpleConnectionHandler.new
