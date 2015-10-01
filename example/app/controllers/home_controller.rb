class HomeController < ApplicationController
  def sleep
    ActiveRecord::Base.connection.execute 'select pg_sleep(1)'
  end

  def index
  end
end
