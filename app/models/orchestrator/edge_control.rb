# frozen_string_literal: true

require 'securerandom'
require 'thread'

module Orchestrator
    class EdgeControl < Couchbase::Model
        design_document :edge
        include ::CouchbaseId::Generator


        StartOrder = Struct.new(:device, :logic, :trigger) do
            def initialize(logger, *args)
                @logger = logger
                super *args
                self.device  ||= []
                self.logic   ||= []
                self.trigger ||= []
            end

            def add(mod_man)
                array = get_type mod_man.settings
                array << mod_man
            end

            def remove(mod_man)
                array = get_type mod_man.settings
                result = array.delete mod_man

                if result.nil?
                    @logger.warn "Slow module removal requested"

                    id = mod_man.settings.id
                    array.delete_if {|mod| mod.settings.id == id }
                end
            end

            def reverse_each
                groups = [self.trigger, self.logic, self.device]
                groups.each do |mods|
                    mods.reverse_each {|mod| yield mod }
                end
            end


            protected


            def get_type(settings)
                type = if settings.respond_to? :role
                    settings.role < 3 ? :device : :logic
                else
                    :trigger
                end
                __send__(type)
            end
        end


        # Engine requires this ENV var to be set for identifying self
        # * ENGINE_EDGE_ID (Can obtain master ID from this)
        # * ENGINE_EDGE_SLAVE = true (multiple slaves, single master, true == slave)
        #
        # Operations:
        # - Request function call
        # - Request status variable
        # - Request repo pull (optional commit specified)
        # - Push: module start / stop / reload
        # - Push: module unload / load (module may be moved to another edge)
        # - Push: module status information
        # - Push: service restart (complete an update)
        # - Push: status variable information to master
        #


        # Note::
        # During any outage, the edge node does not update the database
        # - On recovery the master node will send a list of actions that
        # - have been missed by the edge node. The edge node can process them
        # - then once processed it can request control again.



        # Optional master edge node
        # Allows for multi-master systems versus pure master-slave
        belongs_to :master, class_name: 'Orchestrator::EdgeControl'

        def node_master_id
            return @master_id_sym if @master_id_sym
            @master_id_sym ||= self.master_id.to_sym if self.master_id
            @master_id_sym
        end

        def node_id
            return @id_sym if @id_sym
            @id_sym ||= self.id.to_sym if self.id
            @id_sym
        end


        attribute :name
        attribute :host_origin  # Control UI's need this for secure cross domain connections
        attribute :description

        # Used to validate the connection is from a trusted edge node
        attribute :password,    default: lambda { SecureRandom.hex }

        attribute :failover,    default: true     # should the master take over if this location goes down
        attribute :timeout,     default: 20000   # Failover timeout, how long before we act on the failure? (20seconds default)
        attribute :window_start   # CRON string for recovery windows (restoring edge control after failure)
        attribute :window_length  # Time in seconds

        # Status variables
        attribute :online,          default: true
        attribute :failover_active, default: false
        attribute :failover_time,   default: 0  # Last time there was a failover event
        attribute :startup_time,    default: 0  # Last known time the edge node booted up

        attribute :settings,    default: lambda { {} }
        attribute :admins,      default: lambda { [] }

        attribute :created_at,  default: lambda { Time.now.to_i }


        def self.all
            by_master_id(stale: false)
        end

        def self.salve_of(node_id)
            by_master_id(key: node_id, stale: false)
        end
        view :by_master_id


        attr_reader :proxy
        def slave_connected(proxy, started_at)
            @proxy = proxy

            if @failover_timer
                @failover_timer.cancel
                @failover_timer = nil
            end
            
            if is_failover_host || is_only_master?
                self.online = true
                self.startup_time = started_at

                if self.failover_active == true && self.failover_time < started_at
                    if window_start.nil?
                        restore_slave_control
                    else
                        # TODO implement recovery window timer
                    end
                else
                    # Ensure nothing is running
                    stop_modules
                end

                # TODO:: These saves should use the CAS method as per
                # Module manager status values
                @thread.work do
                    self.save!
                end
            end
        end

        def restore_slave_control
            stop_modules
            # TODO:: send module status dump to slave
            @proxy.restore
        end



        def slave_disconnected
            @proxy = nil

            if @failover_timer.nil? && is_failover_host && @modules_started != true
                @failover_timer = @thread.scheduler.in(self.timeout) do
                    @failover_timer = nil

                    self.online = false
                    self.failover_active = true
                    self.failover_time = Time.now.to_i

                    # TODO:: These saves should use the CAS method as per
                    # Module manager status values
                    @thread.work do
                        self.save!
                    end

                    start_modules
                end

                self.online = false
                self.failover_active = false

                @thread.work do
                    self.save!
                end
            end
        end

        def master_connected(proxy, started_at, failover_at)
            @proxy = proxy

            if should_run_on_this_host
                if failover_at && failover_at < started_at
                    # Master is in control - we wait for a signal
                    self.online = false
                    self.failover_active = true
                else
                    # We are in control - make sure we are online
                    self.online = true
                    self.failover_active = false
                    start_modules

                    # TODO:: Send all status values to master
                end
            end
        end

        def slave_control_restored
            self.online = true
            self.failover_active = false
            start_modules
        end

        def master_disconnected
            # We don't wait for any recover windows.
            # If the master is down then we should be taking control
            @proxy = nil
            slave_control_restored
        end


        def host
            @host ||= self.host_origin.split('//')[-1]
            @host
        end

        def should_run_on_this_host
            @run_here ||= Remote::NodeId == self.node_id
            @run_here
        end

        def is_failover_host
            @fail_here ||= Remote::NodeId == self.node_master_id
            @fail_here
        end

        def is_only_master?
            self.master_id.nil? || node_master_id == node_id
        end

        def host_active?
            @modules_started == true
        end

        def boot(all_systems)
            init
            defer = @thread.defer

            # Don't load anything if this host doesn't have anything to do
            # with the modules in this node
            unless should_run_on_this_host || is_failover_host
                @logger.debug { "init: Ignoring node #{self.id}: #{self.name}" }
                defer.resolve true
                return defer.promise
            end

            @logger.debug { "init: Start loading modules for node #{self.id}: #{self.name}" }

            @global_cache = all_systems
            @loaded = ::Concurrent::Map.new
            @start_order = StartOrder.new @logger

            # Modules are not start until boot is complete
            modules.each do |mod|
                load(mod)
            end

            # Mark system as ready on triggers are loaded
            defer.resolve load_triggers

            # Clear the system cache
            defer.promise.then do
                @boot_complete = true
                @logger.debug { "init: Modules loaded for #{self.id}: #{self.name}" }
                System.clear_cache
            end

            defer.promise
        end


        # Used to transfer control to a newer instance of an edge
        def reloaded(all_systems, loaded, order)
            init

            @global_cache = all_systems
            @loaded = loaded
            @start_order = order
        end


        # Soft start and stop modules (no database updates)
        # TODO:: We need to prevent overlapps
        def start_modules
            return if @modules_started == true
            @modules_started = true

            wait_start(@start_order.device).then do
                wait_start(@start_order.logic).then do
                    wait_start(@start_order.trigger)
                end
            end
        end

        def stop_modules
            return if @modules_started == false
            @modules_started = false

            stopping = []

            @start_order.reverse_each do |mod_man|
                defer = @thread.defer
                stopping << defer.promise

                mod_man.thread.schedule do
                    mod_man.stop_local
                    defer.resolve(true)
                end
            end

            @thread.finally(*stopping)
        end


        # Load the modules on the thread references in round robin
        # This method is thread safe.
        def load(mod_settings)
            mod_id = mod_settings.id.to_sym
            defer = @thread.defer
            mod = @loaded[mod_id]

            if mod
                defer.resolve(mod)
            else
                defer.resolve(
                    @loader.load(mod_settings.dependency).then(proc { |klass|
                        # We will always be on the default thread here
                        thread = @control.selector.next

                        # We'll resolve the promise if the module loads on the deferred thread
                        defer = @thread.defer
                        thread.schedule do
                            defer.resolve init_manager(thread, klass, mod_settings)
                        end

                        # update the module cache
                        defer.promise.then do |mod_manager|
                            @loaded[mod_id] = mod_manager
                            @global_cache[mod_id] = mod_manager
                            @start_order.add mod_manager

                            # Transfer any existing observers over to the new thread
                            # We do this for all modules after boot is complete as
                            # Observers can exist before modules are instantiated
                            if @boot_complete
                                @control.threads.each do |thr|
                                    thr.observer.move(mod_id, thread)
                                end

                                # run the module if it should be running
                                if host_active? && mod_manager.settings.running
                                    thread.schedule do
                                        mod_manager.start_local
                                    end
                                end
                            end

                            # Return the manager
                            mod_manager
                        end
                        defer.promise
                    }, @exceptions)
                )
            end
            defer.promise
        end

        # Symbol input
        def unload(mod_id)
            @global_cache.delete(mod_id)
            mod = @loaded.delete(mod_id)
            @start_order.remove(mod) if mod
        end

        # This is only called from control.
        # The module should not be running at this time
        # TODO:: Should employ some kind of locking (possible race condition here)
        def update(settings)
            # Eager load dependency data whilst not on the reactor thread
            mod_id = settings.id.to_sym

            # Start, stop, unload the module as required
            if should_run_on_this_host || is_failover_host
                return load(settings).then do |mod|
                    mod.start_local if host_active?
                    mod
                end
            end

            nil
        end

        # Returns the list of modules that should be running on this node
        def modules
            Module.on_node(self.id)
        end

        def load_triggers_for(system)
            sys_id = system.id.to_sym
            return if @loaded[sys_id]

            defer = @thread.defer

            thread = @control.selector.next
            thread.schedule do
                mod = Triggers::Manager.new(thread, Triggers::Module, system)
                @loaded[sys_id] = mod  # NOTE:: Threadsafe
                mod.start if @boot_complete && host_active?

                defer.resolve(mod)
            end

            defer.promise.then do |mod_man|
                # Keep track of the order
                @start_order.trigger << mod_man
            end

            defer.promise
        end


        protected


        # When this class is used for managing modules we need access to these classes
        def init
            @thread = ::Libuv::Reactor.default
            @loader = DependencyManager.instance
            @control = Control.instance
            @logger = @control.logger
            self.node_id
            self.master_id
        end

        # Used to stagger the starting of different types of modules
        def wait_start(modules)
            starting = []

            modules.each do |mod_man|
                defer = @thread.defer
                starting << defer.promise
                mod_man.thread.schedule do
                    mod_man.start_local
                    defer.resolve(true)
                end
            end

            # Once load is complete we'll accept websockets
            @thread.finally(*starting)
        end

        # This will always be called on the thread reactor
        def init_manager(thread, klass, settings)
            # Initialize the connection / logic / service handler here
            case settings.dependency.role
            when :device
                Device::Manager.new(thread, klass, settings)
            when :service
                Service::Manager.new(thread, klass, settings)
            else
                Logic::Manager.new(thread, klass, settings)
            end
        end


        def load_triggers
            defer = @thread.defer

            # these are invisible to the system - never make it into the system cache
            result = @thread.work method(:load_trig_system_info)
            result.then do |systems|
                wait_loading = []
                systems.each do |sys|
                    prom = load_triggers_for sys
                    wait_loading << prom if prom
                end

                defer.resolve(@thread.finally(wait_loading))
            end

            # TODO:: Catch trigger load failure

            defer.promise
        end

        # These run like regular modules
        # This function is always run from the thread pool
        # Batch loads the system triggers on to the main thread
        def load_trig_system_info
            begin
                systems = []
                ControlSystem.on_node(self.id).each do |cs|
                    systems << cs
                end
                systems
            rescue => e
                @logger.warn "exception starting triggers #{e.message}"
                sleep 1  # Give it a bit of time
                retry
            end
        end
    end
end
