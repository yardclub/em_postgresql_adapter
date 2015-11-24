require 'active_record/connection_adapters/postgresql_adapter'
require 'pg/em'

module ActiveRecord
  module ConnectionHandling # :nodoc:
    # Establishes a connection to the database that's used by all Active Record objects
    def em_postgresql_connection(config)
      conn_params = config.symbolize_keys

      conn_params.delete_if { |_, v| v.nil? }

      # Map ActiveRecords param names to PGs.
      conn_params[:user] = conn_params.delete(:username) if conn_params[:username]
      conn_params[:dbname] = conn_params.delete(:database) if conn_params[:database]

      # Forward only valid config params to PGconn.connect.
      conn_params.keep_if { |k, _| VALID_CONN_PARAMS.include?(k) }

      # The postgres drivers don't allow the creation of an unconnected PGconn object,
      # so just pass a nil connection object for the time being.
      ConnectionAdapters::EmPostgreSQLAdapter.new(nil, logger, conn_params, config)
    end
  end

  module ConnectionAdapters
    class EmPostgreSQLAdapter < PostgreSQLAdapter
      def connect
        begin
          #@connection = PG::EM::Client.new(@connection_parameters)
          @connection ||= PG::EM::ConnectionPool.new(@connection_parameters)

          # OID::Money.precision = (postgresql_version >= 80300) ? 19 : 10

          configure_connection
        rescue ::PG::Error => error
          if error.message.include?("does not exist")
            raise ActiveRecord::NoDatabaseError.new(error.message)
          else
            raise
          end
        end
      end

      def supports_statement_cache?
        false
      end
    end

    class SimpleConnectionHandler < ConnectionHandler
      def initialize
        @owner_to_pool = Hash.new do |h,k|
          h[k] = Hash.new
        end
        @class_to_pool = Hash.new do |h,k|
          h[k] = Hash.new
        end
      end

      def establish_connection(owner, spec)
        @class_to_pool.clear
        raise RuntimeError, "Anonymous class is not allowed." unless owner.name
        owner_to_pool[owner.name] = ConnectionAdapters::FiberAwareConnectionPool.new(spec)
      end
    end

    class FiberAwareConnectionPool
      attr_accessor :automatic_reconnect, :checkout_timeout
      attr_reader :spec, :connections, :size, :reaper

      def initialize(spec)
        super()

        @spec = spec

        @checkout_timeout = (spec.config[:checkout_timeout] && spec.config[:checkout_timeout].to_f) || 5
        # @reaper  = Reaper.new self, spec.config[:reaping_frequency]
        # @reaper.run

        # default max pool size to 5
        @size = (spec.config[:pool] && spec.config[:pool].to_i) || 5

        # The cache of reserved connections mapped to threads
        @reserved_connections = {}

        @connections         = []
        @automatic_reconnect = true

        @available = []
        @pending = []
      end

      # Retrieve the connection associated with the current thread, or call
      # #checkout to obtain one if necessary.
      #
      # #connection can be called any number of times; the connection is
      # held in a hash keyed by the thread id.
      def connection
        @reserved_connections[current_connection_id] ||= checkout
      end

      # Is there an open connection that is being used for the current thread?
      def active_connection?
        @reserved_connections.fetch(current_connection_id) { return false }.in_use?
      end

      # Signal that the thread is finished with the current connection.
      # #release_connection releases the connection-thread association
      # and returns the connection to the pool.
      def release_connection(with_id = current_connection_id)
        conn = @reserved_connections.delete(with_id)
        checkin conn if conn
      end

      # If a connection already exists yield it to the block. If no connection
      # exists checkout a connection, yield it to the block, and checkin the
      # connection when finished.
      def with_connection
        connection_id = current_connection_id
        fresh_connection = true unless active_connection?
        yield connection
      ensure
        release_connection(connection_id) if fresh_connection
      end

      # Returns true if a connection has already been opened.
      def connected?
        @connections.any?
      end

      # Disconnects all connections in the pool, and clears the pool.
      def disconnect!
        @reserved_connections.clear
        @connections.each do |conn|
          checkin conn
          conn.disconnect!
        end
        @connections = []
        @available.clear
      end

      # Clears the cache which maps classes.
      def clear_reloadable_connections!
        @reserved_connections.clear
        @connections.each do |conn|
          checkin conn
          conn.disconnect! if conn.requires_reloading?
        end
        @connections.delete_if do |conn|
          conn.requires_reloading?
        end
        @available.clear
        @connections.each do |conn|
          @available.add conn
        end
      end

      # Check-out a database connection from the pool, indicating that you want
      # to use it. You should call #checkin when you no longer need this.
      #
      # This is done by either returning and leasing existing connection, or by
      # creating a new connection and leasing it.
      #
      # If all connections are leased and the pool is at capacity (meaning the
      # number of currently leased connections is greater than or equal to the
      # size limit set), an ActiveRecord::ConnectionTimeoutError exception will be raised.
      #
      # Returns: an AbstractAdapter object.
      #
      # Raises:
      # - ConnectionTimeoutError: no connection can be obtained from the pool.
      def checkout
        conn = acquire_connection
        conn.instance_variable_set('@owner', Fiber.current)
        checkout_and_verify(conn)
      end

      # Check-in a database connection back into the pool, indicating that you
      # no longer need this connection.
      #
      # +conn+: an AbstractAdapter object, which was obtained by earlier by
      # calling +checkout+ on this pool.
      def checkin(conn)
        owner = conn.owner

        conn._run_checkin_callbacks do
          conn.expire
        end

        release owner

        @available << conn
      end

      # Remove a connection from the connection pool.  The connection will
      # remain open and active but will no longer be managed by this pool.
      def remove(conn)
        @connections.delete conn
        @available.delete conn

        release conn.owner

        @available.add checkout_new_connection if @available.any_waiting?
      end

      # Recover lost connections for the pool.  A lost connection can occur if
      # a programmer forgets to checkin a connection at the end of a thread
      # or a thread dies unexpectedly.
      def reap
        stale_connections = @connections.select do |conn|
            conn.in_use? && !conn.owner.alive?
        end

        stale_connections.each do |conn|
          if conn.active?
            conn.reset!
            checkin conn
          else
            remove conn
          end
        end
      end

      private

      # Acquire a connection by one of 1) immediately removing one
      # from the queue of available connections, 2) creating a new
      # connection if the pool is not at capacity, 3) waiting on the
      # queue for a connection to become available.
      #
      # Raises:
      # - ConnectionTimeoutError if a connection could not be acquired
      def acquire_connection
        if conn = @available.shift
          conn
        elsif @connections.size < @size
          checkout_new_connection
        else
          reap
          if conn = @available.shift
            conn
          else
            Fiber.yield(@pending.push(Fiber.current))
            acquire_connection
          end
        end
      end

      def release(owner)
        fiber_id = owner.object_id
        @reserved_connections.delete fiber_id
      end

      def new_connection
        Base.send(spec.adapter_method, spec.config)
      end

      def current_connection_id #:nodoc:
        Base.connection_id ||= Fiber.current.object_id
      end

      def checkout_new_connection
        raise ConnectionNotEstablished unless @automatic_reconnect

        c = new_connection
        c.pool = self
        @connections << c
        c
      end

      def checkout_and_verify(c)
        c._run_checkout_callbacks do
          c.verify!
        end
        c
      end
    end
  end
end
