# frozen_string_literal: true

require 'logger'

module Orchestrator
    class Control
        include Singleton

        #
        #
        # 1. Load the modules allocated to this node
        # 2. Allocate modules to CPUs
        #    * Modules load dependencies as required
        #    * Logics are streamed in after devices and services
        #
        # Logic modules will fetch their system when they interact with other modules.
        #  Devices and services do not have a system associated with them
        # This makes systems very loosely coupled to the modules
        #  which should make distributing the system slightly simpler
        #
        #

        def initialize
            # critical sections
            @critical = ::Mutex.new
            @loaded = ::Concurrent::Map.new
            @zones = ::Concurrent::Map.new
            @nodes = ::Concurrent::Map.new
            @connections = ::Concurrent::Map.new
            @reactor = ::Libuv::Reactor.default

            @next_thread = Concurrent::AtomicFixnum.new

            @ready = false
            @ready_defer = @reactor.defer
            @ready_promise = @ready_defer.promise
            @ready_promise.then do
                @ready = true
            end

            logger = ::MonoLogger.new(STDOUT)
            logger.formatter = proc { |severity, datetime, progname, msg|
                "#{datetime.strftime("%d/%m/%Y @ %I:%M%p")} #{severity}: #{msg}\n"
            }
            @logger = ::ActiveSupport::TaggedLogging.new(logger)
        end


        attr_reader :logger, :reactor, :ready, :ready_promise, :zones, :nodes, :threads


        # Start the control reactor
        def mount
            return @server.loaded if @server
            promise = nil

            @critical.synchronize {
                return if @server   # Protect against multiple mounts

                logger.debug 'init: Mounting Engine'

                # 5min fail safe check to ensure system has booted.
                # Couchbase sometimes never responds when it is booting.
                @reactor.scheduler.in('5m') do
                    if not @ready
                        STDERR.puts "\n\nSYSTEM BOOT FAILURE:\n\n"
                        dump_thread_backtraces
                        @reactor.next_tick { Process.kill('SIGKILL', Process.pid) }
                    end
                end

                # Cache all the zones in the system
                ::Orchestrator::Zone.all.each do |zone|
                    @zones[zone.id] = zone
                end

                logger.debug 'init: Zones loaded'

                @server = ::SpiderGazelle::Spider.instance
                promise = @server.loaded.then do
                    # Share threads with SpiderGazelle (one per core)
                    if @server.in_mode? :thread
                        logger.debug 'init: Running in threaded mode'

                        start_watchdog
                        @threads = @server.threads
                        @threads.each do |thread|
                            thread.schedule do
                                attach_watchdog(thread)
                            end
                        end

                        logger.debug 'init: Watchdog started'
                    else    # We are running in no_ipc mode (or process mode, unsupported for control)
                        @threads = []

                        logger.debug 'init: Running in process mode (starting threads)'

                        cpus = ::Libuv.cpu_count || 1
                        start_watchdog
                        cpus.times { |i| start_thread(i) }

                        logger.debug 'init: Watchdog started'
                    end
                end
            }

            return promise
        end

        def next_thread
            index = 0
            @next_thread.update { |val|
                index = val
                next_val = val + 1
                next_val = 0 if next_val >= @threads.length
                next_val
            }
            @threads[index]
        end

        # Boot the control system, running all defined modules
        def boot(*args)
            # Only boot if running as a server
            Thread.new { load_all }
        end

        # Load a zone that might have been missed or added manually
        # The database etc
        # This function is thread safe
        def load_zone(zone_id)
            zone = @zones[zone_id]
            return zone if zone

            tries = 0
            begin
                zone = ::Orchestrator::Zone.find(zone_id)
                @zones[zone.id] = zone
                zone
            rescue => e
                if !e.is_a?(Libcouchbase::Error::KeyNotFound) && tries <= 3
                    @reactor.sleep 200
                    tries += 1
                    retry
                else
                    raise e
                end
            end
        end

        # Loads the module requested
        #
        # @return [::Libuv::Q::Promise]
        def load(id, do_proxy = true)
            mod_id = id.to_sym
            defer = @reactor.defer

            mod = @loaded[mod_id]
            if mod
                defer.resolve(mod)
            else
                @reactor.schedule do
                    # Grab the database model
                    tries = 0
                    begin
                        config = ::Orchestrator::Module.find(mod_id)

                        # Load the module if model found
                        edge = @nodes[config.edge_id.to_sym]
                        result = edge.update(config)

                        if result
                            defer.resolve(result)
                            result.then do |mod|
                                # Signal the remote node to load this module
                                mod.remote_node {|proxy| remote.load(mod_id) } if do_proxy

                                # Expire the system cache
                                ControlSystem.using_module(id).each do |sys|
                                    expire_cache sys.id, no_update: true
                                end
                            end
                        else
                            err = Error::ModuleUnavailable.new "module '#{mod_id}' not assigned to node #{edge.name} (#{edge.host_origin})"
                            defer.reject(err)
                        end

                    rescue Libcouchbase::Error::KeyNotFound => e
                        err = Error::ModuleNotFound.new "unable to start module '#{mod_id}', not found"
                        defer.reject(err)
                    rescue => e
                        tries += 1
                        if tries < 3
                            @reactor.sleep 200
                            retry
                        end
                        raise e
                    end
                end
            end

            defer.promise
        end

        # Checks if a module with the ID specified is loaded
        def loaded?(mod_id)
            @loaded[mod_id.to_sym]
        end

        def get_node(edge_id)
            @nodes[edge_id.to_sym]
        end

        # Starts a module running
        def start(mod_id, do_proxy = true, system_level: false)
            defer = @reactor.defer

            # No need to proxy this load as the remote will load
            # when it runs start
            loading = load(mod_id, false)
            loading.then do |mod|
                if system_level && mod.settings.ignore_startstop
                    defer.resolve true
                else
                    if do_proxy
                        mod.remote_node do |remote|
                            @reactor.schedule do
                                remote.start mod_id
                            end
                        end
                    end

                    mod.thread.schedule do
                        defer.resolve(mod.start)
                    end
                end
            end
            loading.catch do |err|
                err = Error::ModuleNotFound.new "unable to start module '#{mod_id}', not found"
                defer.reject(err)
                @logger.warn err.message
            end

            defer.promise
        end

        # Stops a module running
        def stop(mod_id, do_proxy = true, system_level: false)
            defer = @reactor.defer

            mod = loaded? mod_id
            if mod
                if system_level && mod.settings.ignore_startstop
                    defer.resolve mod
                else
                    if do_proxy
                        mod.remote_node do |remote|
                            @reactor.schedule do
                                remote.stop mod_id
                            end
                        end
                    end

                    mod.thread.schedule do
                        mod.stop
                        defer.resolve(mod)
                    end
                end
            else
                err = Error::ModuleNotFound.new "unable to stop module '#{mod_id}', might not be loaded"
                defer.reject(err)
                @logger.warn err.message
            end

            defer.promise
        end

        # Stop the module gracefully
        # Then remove it from @loaded
        def unload(mod_id, do_proxy = true)
            mod = mod_id.to_sym

            stop(mod, false).then(proc { |mod_man|
                if do_proxy
                    mod_man.remote_node do |remote|
                        remote.unload mod
                    end
                end

                # Unload the module locally
                @nodes[Remote::NodeId].unload(mod)
                nil # promise response
            })
        end

        # Unload then
        # Get a fresh version of the settings from the database
        # load the module
        def update(mod_id, do_proxy = true)
            defer = @reactor.defer

            # We want to unload on the current remote (this might be what we are updating)
            unload(mod_id, do_proxy).finally do
                # We don't want to load on the current remote (it might have changed)
                defer.resolve load(mod_id, false)
            end

            # Perform the proxy after we've completed the load here
            if do_proxy
                defer.promise.then do |mod_man|
                    mod_man.remote_node do |remote|
                        remote.load mod_id
                    end
                end
            end

            defer.promise
        end

        def expire_cache(sys_id, remote = true, no_update: nil)
            loaded = []

            if remote
                nodes.values.each do |node|
                    promise = node.proxy&.expire_cache(sys_id)
                    loaded << promise if promise
                end
            end

            sys = ControlSystem.find_by_id(sys_id)
            if sys
                sys.expire_cache(no_update)
            else
                System.expire(sys_id)
            end

            reactor.finally(*loaded)
        end

        def clear_cache(remote = true)
            loaded = []

            if remote
                nodes.values.each do |node|
                    promise = node.proxy&.clear_cache
                    loaded << promise if promise
                end
            end

            System.clear_cache

            reactor.finally(*loaded)
        end

        def log_unhandled_exception(error, context, trace = nil)
            @logger.print_error error, context
            ::Libuv::Q.reject(@reactor, error)
        end


        protected


        # Grab the modules from the database and load them
        def load_all
            loading = []

            logger.debug 'init: Loading edge node details'

            nodes = ::Orchestrator::EdgeControl.all
            nodes.each do |node|
                @nodes[node.id.to_sym] = node
                loading << node.boot(@loaded)
            end

            # Once load is complete we'll accept websockets
            @reactor.finally(*loading).finally do
                logger.debug 'init: Connecting to edge nodes'

                # Determine if we are the master node (either single master or load balanced masters)
                this_node = @nodes[Remote::NodeId]

                # Start remote node server and connect to nodes
                @node_server = Remote::Master.new
                @nodes.each_value do |remote_node|
                    next if this_node == remote_node
                    @connections[remote_node.id] = ::UV.connect remote_node.host, remote_node.server_port, Remote::Edge, this_node, remote_node
                end

                # Save a statistics snapshot every 5min on the master server
                # TODO:: we could have this auto-negotiated in the future
                unless ENV['COLLECT_STATS'] == 'false'
                    logger.debug 'init: Collecting cluster statistics'
                    @reactor.scheduler.every(300_000) do
                        begin
                            Orchestrator::Stats.new.save
                        rescue => e
                            @logger.warn "exception saving statistics: #{e.message}"
                        end
                    end
                end

                logger.debug 'init: Init complete'
                @ready_defer.resolve(true)
            end
        end


        ##
        # Methods called when we manage the threads:
        def start_thread(num)
            thread = Libuv::Reactor.new
            @threads << thread

            Thread.new do
                thread.notifier { |*args| log_unhandled_exception(*args) }
                thread.run do |thread|
                    attach_watchdog thread
                end
            end
        end


        # =============
        # WATCHDOG CODE
        # =============
        def attach_watchdog(thread)
            @last_seen[thread] = @watchdog.now

            thread.scheduler.every 3000 do
                @last_seen[thread] = @watchdog.now
            end
        end

        # Monitors threads to make sure they continue to checkin
        # If a thread is hung then we log what it happening
        # If it still doesn't checked in then we raise an exception
        # If it still doesn't checkin then we shutdown
        def start_watchdog
            thread = Libuv::Reactor.new
            @last_seen = ::Concurrent::Map.new
            @watching = false

            Thread.new do
                thread.notifier { |*args| log_unhandled_exception(*args) }
                thread.run do |thread|
                    thread.scheduler.every(8000) { check_threads }
                    thread.scheduler.every('2h1s') { sync_connected_state }
                end
            end
            @watchdog = thread
        end

        def check_threads
            now = @watchdog.now
            should_kill = false
            watching = false

            @threads.each do |thread|
                difference = now - (@last_seen[thread] || 0)

                if difference > 30000
                    should_kill = true
                    watching = Rails.env.production?
                elsif difference > 12000
                    watching = true
                end
            end

            if watching
                @logger.error "WATCHDOG ACTIVATED" if !@watching
                dump_thread_backtraces
            end

            @watching = watching

            if should_kill
                if Rails.env.production?
                    @logger.fatal "SYSTEM UNRESPONSIVE - FORCING SHUTDOWN"
                    Process.kill 'SIGKILL', Process.pid
                else
                    @logger.error "SYSTEM UNRESPONSIVE - in development mode a shutdown isn't forced"
                end
            end
        end

        def dump_thread_backtraces
            Thread.list.each do |t|
                backtrace = t.backtrace
                STDERR.puts "#" * 90
                STDERR.puts t.inspect
                STDERR.puts backtrace ? backtrace.join("\n") : 'no backtrace'
                STDERR.puts "#" * 90
            end
            STDERR.flush
        end
        # =================
        # END WATCHDOG CODE
        # =================

        # Backup code for ensuring metrics is accurate
        def sync_connected_state
            @loaded.values.each do |mod|
                mod.thread.schedule { mod.__send__(:update_connected_status) }
            end
        end
    end
end
