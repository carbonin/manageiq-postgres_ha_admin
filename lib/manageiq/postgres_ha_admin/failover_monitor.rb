require 'active_support/all'
require 'pg'
require 'linux_admin'

module ManageIQ
module PostgresHaAdmin
  class FailoverMonitor
    include Logging

    RAILS_ROOT = [
      Pathname.new("/var/www/miq/vmdb"),
      Pathname.new(File.expand_path(File.join(__dir__, "../..")))
    ].detect { |f| File.exist?(f) }
    FAILOVER_ATTEMPTS = 10
    DB_CHECK_FREQUENCY = 300
    FAILOVER_CHECK_FREQUENCY = 60
    attr_accessor :failover_attempts, :db_check_frequency, :failover_check_frequency

    def initialize(db_yml_file: '/var/www/miq/vmdb/config/database.yml',
                   failover_yml_file: '/var/www/miq/vmdb/config/failover_databases.yml',
                   ha_admin_yml_file: '/var/www/miq/vmdb/config/ha_admin.yml',
                   environment: 'production')
      @database_yml = DatabaseYml.new(db_yml_file, environment)
      @server_store = ServerStore.new(failover_yml_file)
      initialize_settings(ha_admin_yml_file)
    end

    def monitor
      connection = pg_connection(@database_yml.read)
      if connection
        @server_store.update_failover_yml(connection)
        connection.finish
        return
      end

      logger.error("Primary Database is not available. EVM server stop initiated. Starting to execute failover...")
      stop_evmserverd

      if execute_failover
        start_evmserverd
        raise_failover_event
      else
        logger.error("Failover failed")
      end
    end

    def monitor_loop
      loop do
        begin
          monitor
        rescue => err
          logger.error("#{err.class}: #{err}")
          logger.error(err.backtrace.join("\n"))
        end
        sleep(db_check_frequency)
      end
    end

    def active_servers_conninfo
      servers = @server_store.active_databases_conninfo_hash
      db_yml_params = @database_yml.read
      servers.map! { |info| db_yml_params.merge(info) }
    end

    def raise_failover_event
      require "awesome_spawn"
      AwesomeSpawn.run("rake evm:raise_server_event",
                       :chdir  => RAILS_ROOT,
                       :params => ["--", {:event  => "db_failover_executed"}])
    end

    private

    def initialize_settings(ha_admin_yml_file)
      begin
        ha_admin_yml = YAML.load_file(ha_admin_yml_file)
      rescue SystemCallError, IOError => err
        ha_admin_yml = {}
        logger.error("#{err.class}: #{err}")
        logger.info("File not loaded: #{ha_admin_yml_file}. Default settings for failover will be used.")
      end
      @failover_attempts = ha_admin_yml['failover_attempts'] || FAILOVER_ATTEMPTS
      @db_check_frequency = ha_admin_yml['db_check_frequency'] || DB_CHECK_FREQUENCY
      @failover_check_frequency = ha_admin_yml['failover_check_frequency'] || FAILOVER_CHECK_FREQUENCY
      logger.info("FAILOVER_ATTEMPTS=#{@failover_attempts} DB_CHECK_FREQUENCY=#{@db_check_frequency} FAILOVER_CHECK_FREQUENCY=#{@failover_check_frequency}")
    end

    def execute_failover
      failover_attempts.times do
        with_each_standby_connection do |connection, params|
          next if database_in_recovery?(connection)
          next unless @server_store.host_is_repmgr_primary?(params[:host], connection)
          logger.info("Failing over to server using conninfo: #{params.reject { |k, _v| k == :password }}")
          @server_store.update_failover_yml(connection)
          @database_yml.write(params)
          return true
        end
        sleep(failover_check_frequency)
      end
      false
    end

    def with_each_standby_connection
      active_servers_conninfo.each do |params|
        connection = pg_connection(params)
        next if connection.nil?
        begin
          yield connection, params
        ensure
          connection.finish
        end
      end
    end

    def pg_connection(params)
      PG::Connection.open(params)
    rescue PG::Error => e
      logger.error("Failed to establish PG connection: #{e.message}")
      nil
    end

    def start_evmserverd
      LinuxAdmin::Service.new("evmserverd").restart
      logger.info("Starting EVM server from failover monitor")
    end

    def stop_evmserverd
      LinuxAdmin::Service.new("evmserverd").stop
    end

    # Checks if postgres database is in recovery mode
    #
    # @param pg_connection [PG::Connection] established pg connection
    # @return [Boolean] true if database in recovery mode
    def database_in_recovery?(pg_connection)
      pg_connection.exec("SELECT pg_catalog.pg_is_in_recovery()") do |db_result|
        result = db_result.map_types!(PG::BasicTypeMapForResults.new(pg_connection)).first
        result['pg_is_in_recovery']
      end
    end
  end
end
end
