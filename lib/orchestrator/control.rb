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
            @reactor = ::Libuv::Reactor.default
            @exceptions = method(:log_unhandled_exception)

            @next_thread = Concurrent::AtomicFixnum.new

            @ready = false
            @ready_defer = @reactor.defer
            @ready_promise = @ready_defer.promise
            @ready_promise.then do
                @ready = true
            end

            logger = ::Logger.new(STDOUT)
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
                        cpus.times &method(:start_thread)

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
            Thread.new &method(:load_all)
        end

        # Load a zone that might have been missed or added manually
        # The database etc
        # This function is thread safe
        def load_zone(zone_id)
            zone = @zones[zone.id]
            return zone if zone

            tries = 0
            begin
                zone = ::Orchestrator::Zone.find(zone_id)
                @zones[zone.id] = zone
                zone
            rescue => e
                if !e.is_a?(Libcouchbase::Error::KeyNotFound) && tries <= 2
                    sleep 1
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
                                    sys.expire_cache(:no_update)
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
        def start(mod_id, do_proxy = true)
            defer = @reactor.defer

            # No need to proxy this load as the remote will load
            # when it runs start
            loading = load(mod_id, false)
            loading.then do |mod|
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
            loading.catch do |err|
                err = Error::ModuleNotFound.new "unable to start module '#{mod_id}', not found"
                defer.reject(err)
                @logger.warn err.message
            end

            defer.promise
        end

        # Stops a module running
        def stop(mod_id, do_proxy = true)
            defer = @reactor.defer

            mod = loaded? mod_id
            if mod
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
                this_node   = @nodes[Remote::NodeId]
                master_node = @nodes[this_node.node_master_id]
                connect_to_master(this_node, master_node) if master_node

                if master_node.nil? || this_node.is_failover_host || (master_node && master_node.is_failover_host)
                    start_server

                    # Save a statistics snapshot every 5min on the master server
                    @reactor.scheduler.every(300_000, method(:log_stats))
                end

                logger.debug 'init: Init complete'

                @ready_defer.resolve(true)
            end
        end


        def log_stats(*_)
            Orchestrator::Stats.new.save
        rescue => e
            @logger.warn "exception saving statistics: #{e.message}"
        end


        ##
        # Methods called when we manage the threads:
        def start_thread(num)
            thread = Libuv::Reactor.new
            @threads << thread

            Thread.new do
                thread.notifier @exceptions
                thread.run do |thread|
                    attach_watchdog thread
                end
            end
        end


        # =============
        # WATCHDOG CODE
        # =============
        def attach_watchdog(thread)
            @watchdog.schedule do
                @last_seen[thread] = @watchdog.now
            end

            thread.scheduler.every 1000 do
                @watchdog.schedule do
                    @last_seen[thread] = @watchdog.now
                end
            end
        end

        IgnoreClasses = ['Libuv::', 'Concurrent::', 'UV::', 'Set', '#<Class:Bisect>', '#<Class:Libuv', 'IO', 'FSEvent', 'ActiveSupport', 'Listen::', 'Orchestrator::Control'].freeze
        # Monitors threads to make sure they continue to checkin
        # If a thread is hung then we log what it happening
        # If it still doesn't checked in then we raise an exception
        # If it still doesn't checkin then we shutdown
        def start_watchdog
            thread = Libuv::Reactor.new
            @last_seen = {}
            @watching = false

            if defined? ::TracePoint
                @trace = ::TracePoint.new(:line, :call, :return, :raise) do |tp|
                    klass = "#{tp.defined_class}"
                    unless klass.start_with?(*IgnoreClasses)
                        @logger.info "tracing #{tp.event} from #{tp.defined_class}##{tp.method_id}:#{tp.lineno} in #{tp.path}"
                    end
                end
            end

            Thread.new do
                thread.notifier @exceptions
                thread.run do |thread|
                    thread.scheduler.every 2000 do
                        check_threads
                    end
                end
            end
            @watchdog = thread
        end

        def check_threads
            now = @watchdog.now
            watching = false

            @threads.each do |thread|
                difference = now - (@last_seen[thread] || 0)

                if difference > 5000
                    if difference > 10000
                        @logger.fatal "SYSTEM UNRESPONSIVE - FORCING SHUTDOWN"
                        Process.kill 'SIGKILL', Process.pid
                    else
                        # we want to start logging
                        watching = true
                    end
                end
            end

            if !@watching && watching
                @logger.warn "WATCHDOG ACTIVATED"

                # Dump the thread bracktraces
                Thread.list.each do |t|
                    STDERR.puts "#" * 90
                    STDERR.puts t.inspect
                    STDERR.puts t.backtrace
                    STDERR.puts "#" * 90
                end
                STDERR.flush

                @watching = true
                @trace.enable if defined? ::TracePoint
            elsif @watching && !watching
                @watching = false
                @trace.disable if defined? ::TracePoint
            end
        end
        # =================
        # END WATCHDOG CODE
        # =================


        # Edge node connections
        def start_server
            @node_server = Remote::Master.new
        end

        def connect_to_master(this_node, master)
            @connection = ::UV.connect master.host, Remote::SERVER_PORT, Remote::Edge, this_node, master
        end
    end
end
