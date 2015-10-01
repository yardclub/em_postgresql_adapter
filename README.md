# em_postgresql_adapter

PostgreSQL adapter for ActiveRecord using non-blocking I/O and Fibers

## Installation

Add this to your application's `Gemfile:

```ruby
gem 'em_postgresql_adapter', git: 'git://github.com/PavelPenkov/em_postgresql_adapter.git'
gem 'thin'
gem 'rack-fiber_pool'
```

Change adapter in `config/database.yml` from `postgresql` to `em_postgresql`

Add these lines to `config/application.rb`

```ruby
config.middleware.insert_before Rack::Sendfile, Rack::FiberPool
config.middleware.delete Rack::Lock # Thin is single-threaded so this is useless
config.middleware.delete ActiveRecord::QueryCache # Acquires connection before it's really needed starving the connection pool
```

## Usage

Just use ActiveRecord as usual. DB requests won't block the reactor `thin` runs allowing it process requests from other clients.
