# frozen_string_literal: true

require 'securerandom'
require 'thread'

module Orchestrator
    class EdgeControl < CouchbaseOrm::Base
        design_document :edge


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


        attribute :name,          type: String
        attribute :host_origin,   type: String  # Control UI's need this for secure cross domain connections
        attribute :description,   type: String

        # Used to validate the connection is from a trusted edge node
        attribute :password,      type: String,  default: lambda { SecureRandom.hex }

        attribute :failover,      type: Boolean, default: true     # should the master take over if this location goes down
        attribute :timeout,       type: Integer, default: 20000   # Failover timeout, how long before we act on the failure? (20seconds default)
        attribute :window_start,  type: String   # CRON string for recovery windows (restoring edge control after failure)
        attribute :window_length, type: Integer  # Time in seconds

        # Status variables
        attribute :online,          type: Boolean, default: true
        attribute :failover_active, type: Boolean, default: false
        attribute :failover_time,   type: Integer, default: 0  # Last time there was a failover event
        attribute :startup_time,    type: Integer, default: 0  # Last known time the edge node booted up
        attribute :server_port,     type: Integer, default: 17400

        attribute :settings,   type: Hash,    default: lambda { {} }
        attribute :admins,     type: Array,   default: lambda { [] }

        attribute :created_at, type: Integer, default: lambda { Time.now }


        def self.all
            by_master_id
        end
        index_view :master_id, find_method: :salve_of, validate: false


        attr_reader :proxy

        # The server representing this node has connected to this server.
        # This function coordinates who should be controlling the devices
        def slave_connected(proxy, started_at)
            @proxy = proxy

            if @failover_timer
                @failover_timer.cancel
                @failover_timer = nil
            end

            # If this server is the failover host for this node / edge then
            # we want to restore control of the devices to the host node.
            if is_failover_host
                self.reload # The slave may have taken back control

                begin
                    self.online = true
                    self.startup_time = started_at
                    self.save!(with_cas: true)
                rescue ::Libcouchbase::Error::KeyExists
                    self.reload
                    retry
                end

                # We check if the host considered us in control of the devices
                # If it did then we restore control.
                if self.failover_active == true && self.failover_time < started_at

                    # Window start indicates the best time to restore control
                    if window_start.nil?
                        restore_slave_control
                    else
                        # TODO implement recovery window timer
                    end
                else
                    # This was a network partition - the other node never went down
                    # and is still controlling devices, we should make sure we are
                    # not attempting to control anything.
                    stop_modules
                end
            end
        end

        def restore_slave_control
            stop_modules
            transfer_state
            @proxy.restore
        end


        # The server representing this node has disconnected from this server.
        # The server might be down... We start the timer and take control as required
        def slave_disconnected
            @proxy = nil

            if @failover_timer.nil? && is_failover_host && @modules_started != true

                # If the node reconnects then this timer will be cancelled
                @failover_timer = @thread.scheduler.in(self.timeout) do
                    @failover_timer = nil

                    begin
                        self.online = false
                        self.failover_active = true
                        self.failover_time = Time.now.to_i
                        self.save!(with_cas: true)
                    rescue ::Libcouchbase::Error::KeyExists
                        self.reload
                        retry
                    end

                    start_modules
                end

                # Update state to indicate we've lost the node however the failover hasn't occured yet
                begin
                    self.online = false
                    self.failover_active = false
                    self.save!(with_cas: true)
                rescue ::Libcouchbase::Error::KeyExists
                    self.reload
                    retry
                end
            end
        end

        # The connecting node is the failover host if this host goes down
        # Each host passes their boot times - which is used to determine who should have control
        # The slave connection mutates the database state - not the master connection
        # (DB values are update here to match what the slave connection would persist)
        def master_connected(proxy, started_at, failover_at)
            @proxy = proxy
            transfer_state if @modules_started

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
                end
            end
        end

        # The failover host has disconnected - we assume the server has gone down
        # We don't wait for any recover windows.
        # If the master is down then we should be taking control
        def master_disconnected
            @proxy = nil
            slave_control_restored if should_run_on_this_host
        end

        def slave_control_restored
            self.reload
            begin
                self.online = true
                self.failover_active = false
                self.save!(with_cas: true)
            rescue ::Libcouchbase::Error::KeyExists
                self.reload
                retry
            end
            start_modules
        end

        def host
            @host ||= self.host_origin.split('//')[-1]
            @host
        end

        def should_run_on_this_host
            @run_here ||= Remote::NodeId == self.node_id
        end

        def is_failover_host
            @fail_here ||= Remote::NodeId == self.node_master_id
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
            promises = []
            modules.each do |mod|
                promises << load(mod)
            end

            # Mark system as ready on triggers are loaded
            promises << load_triggers
            defer.resolve @thread.all(promises)

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
                        thread = @control.next_thread

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
                                    # Check if move is required before the schedule
                                    thr.schedule { thr.observer.move(mod_id, mod_manager.thread) }
                                end

                                # run the module if it should be running
                                if host_active? && mod_manager.settings.running
                                    mod_manager.thread.schedule do
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
        # NOTE:: possibility that update could be called twice before module started?
        def update(settings)
            # Eager load dependency data whilst not on the reactor thread
            mod_id = settings.id.to_sym

            # Start, stop, unload the module as required
            if should_run_on_this_host || is_failover_host
                return load(settings).then do |mod|
                    mod.thread.schedule { mod.start_local } if host_active?
                    mod
                end
            end

            nil
        end

        # Returns the list of modules that should be running on this node
        def modules
            ::Orchestrator::Module.on_node(self.id)
        end

        def load_triggers_for(system)
            sys_id = system.id.to_sym
            return if @loaded[sys_id]

            defer = @thread.defer

            thread = @control.next_thread
            thread.schedule do
                mod = Triggers::Manager.new(thread, Triggers::Module, system)
                @loaded[sys_id] = mod  # NOTE:: Threadsafe
                @global_cache[sys_id] = mod
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

        BATCH_LOAD_SIZE = (ENV['BATCH_LOAD_SIZE'] || 200).to_i
        BATCH_LOAD_DELAY = (ENV['BATCH_LOAD_DELAY'] || 4000).to_i

        # Used to stagger the starting of different types of modules
        def wait_start(modules)
            starting = []

            modules.each_slice(BATCH_LOAD_SIZE) do |batch|
                batch.each do |mod_man|
                    defer = @thread.defer
                    starting << defer.promise
                    mod_man.thread.schedule do
                        mod_man.start_local
                        defer.resolve(true)
                    end
                end
                reactor.scheduler.in(BATCH_LOAD_DELAY) { true }.value
            end

            # Once load is complete we'll accept websockets
            @thread.finally(*starting)
        end

        # This will always be called on the thread reactor
        def init_manager(thread, klass, settings)
            # Initialize the connection / logic / service handler here
            case settings.dependency.role
            when :ssh
                Ssh::Manager.new(thread, klass, settings)
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
            wait_loading = []
            ControlSystem.on_node(self.id).each do |sys|
                prom = load_triggers_for sys
                wait_loading << prom if prom
            end

            defer.resolve(@thread.finally(wait_loading))
            defer.promise
        rescue Exception => e
            @logger.error "fatal error while loading triggers\n#{e.message}\n#{e.backtrace.join("\n")}"
            @thread.sleep 200
            Process.kill 'SIGKILL', Process.pid
            @thread.sleep 200
            abort("Failed to load. Killing process.")
        end

        def transfer_state
            [:device, :logic, :trigger].each do |method|
                @start_order.__send__(method).each do |mod|
                    @proxy.sync_status(mod.settings.id, mod.status)
                end
            end
        rescue => e
            # TODO:: log this error
            puts "Error transferring module status\n#{e.message}\n#{e.backtrace.join("\n")}"
        end
    end
end
