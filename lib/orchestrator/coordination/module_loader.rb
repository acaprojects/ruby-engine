# frozen_string_literal: true

require 'thread'
require 'singleton'
require 'concurrent'

module Orchestrator; end
class Orchestrator::ModuleLoader
    include Singleton

    def initialize
        # Ensure only a single state change is applied to
        @queue = ::Queue.new
        @state = ::Concurrent::AtomicReference.new
        @nodes = ::Orchestrator::ClusterState.instance
        @nodes.cluster_change do |node_count|
            @state.set node_count
            @queue << nil
        end

        # Both solid and remote proxies
        @modules = ::Concurrent::Map.new

        # These are decrypted database models
        @dependencies = ::Orchestrator::DependencyCache.instance
        @systems = Orchestrator::SystemCache.instance

        # These are the loaded ruby classes
        @loader = ::Orchestrator::DependencyManager.instance

        # This coordinates API interactions
        @control = ::Orchestrator::Control.instance

        # block this thread until updates are completed on the reactor thread
        @state_mutex = ::Mutex.new
        @state_loaded = ::ConditionVariable.new

        # Current state of the node
        @loaded = {}
        @current_count = 0
        @processing = false
        @logger = ::Rails.logger

        # Every 10min we want to ensure state as a fail safe
        # The failsafe is ignored if any processing is currently occuring
        @thread = ::Libuv::Reactor.default
        @thread.schedule do
            @thread.scheduler.every('10m') do
                next if @processing || !@queue.empty?
                @queue << nil if @state.compare_and_set(nil, @current_count)
            end
        end
        @statistics = nil

        # Start the node
        ::Thread.new { process_changes! }
    end

    def module_created(mod_id)
        defer = ::Libuv::Reactor.current.defer
        @queue << [defer, true, mod_id]
        defer.promise
    end

    def module_destroyed(mod_id)
        defer = ::Libuv::Reactor.current.defer
        @queue << [defer, false, mod_id]
        defer.promise
    end

    def get(mod_id)
        mod = @modules[mod_id]
        # We should probably make managers a shell where we can swap out solid
        # implementations for remote proxies without changing the references?
        if mod.nil?
            if ::Libuv::Reactor.current
                mod = module_created(mod_id).value
            else
                # perform a blocking load - edge case where system cache update
                # is triggered from a thread pool
                loading = ::Mutex.new
                loaded = ::ConditionVariable.new
                loading.synchronize do
                    @thread.schedule do
                        mod = get(mod_id)
                        loading.synchronize { loaded.broadcast }
                    end
                    loaded.wait(loading)
                end
            end
        end
        mod
    end

    def check(mod_id)
        @modules[mod_id]
    end

    private

    # This ensures that changes to actively running modules are serialised.
    # NOTE:: This is only tracking what is loaded. Not starting or stopping anything
    def process_changes!
        loop do
            defer, change, mod_id = @queue.pop
            @processing = true

            # individual module change
            if mod_id
                sync_sched('error changing %s, state: %s', mod_id, change) do
                    if change
                        # Triggers have their own special load function
                        locally = @nodes.running_locally?(mod_id)
                        if mod_id.start_with?('s') && locally
                            load_trigger(@systems.get(mod_id).config, defer: defer)
                        else
                            load_module(mod_id, defer: defer, run_locally: locally)
                        end
                    else
                        unload_module(mod_id, defer: defer)
                    end
                end
            else
                # complete state change - node added or removed from the cluster
                new_count = @state.get_and_set(nil)
                if new_count
                    sync_sched('error processing cluster state changes') do
                        # This might be retrying so the state check is worth while
                        new_count = @state.get_and_set(nil) || new_count
                        update_state(new_count)
                        @current_count = new_count
                    end
                end

                # TODO:: Implement node ready coordination
                @nodes.signal_ready(@current_count) if @queue.empty?
            end

            @processing = !@queue.empty?
        end
    end

    def load_module(mod_id, mod: nil, defer: nil, run_locally: nil)
        run_locally = @nodes.running_locally?(mod_id) if run_locally.nil?
        mod = ::Orchestrator::Module.find(mod_id) unless mod

        raise 'module not found' if mod.nil?

        if run_locally
            # load dependency model from cache (encryption is pre-processed)
            mod.dependency = @dependencies.get(mod.dependency_id)
            klass = @loader.load(mod.dependency).value
            thread = @control.next_thread

            # decrypt the settings
            reactor.work { mod.deep_decrypt }.value

            # This performs the actual load of the module
            defer = @thread.defer
            thread.schedule do
                defer.resolve init_manager(thread, klass, mod)
            end

            loaded = defer.promise.value
            @modules[mod_id] = loaded
            defer.resolve(loaded) if defer
        else
            # TODO:: laod the remote proxy
        end

    rescue => error
        @logger.warn [
            'failed to load module',
            error.message,
            error.backtrace&.join("\n")
        ].join("\n")

        # ensure there aren't any expired references
        @modules.delete(mod_id)
        defer.resolve(nil) if defer
    end

    def init_manager(thread, klass, settings)
        # Initialize the connection / logic / service handler here
        case settings.dependency.role
        when :ssh
            ::Orchestrator::Ssh::Manager.new(thread, klass, settings)
        when :device
            ::Orchestrator::Device::Manager.new(thread, klass, settings)
        when :service
            ::Orchestrator::Service::Manager.new(thread, klass, settings)
        else
            ::Orchestrator::Logic::Manager.new(thread, klass, settings)
        end
    end

    def unload_module(mod_id, defer: nil)
        manager = @modules.delete(mod_id)
        # stop local as we don't want to update the database state
        manager&.stop_local
        defer.resolve(true) if defer
    end

    def load_trigger(system, defer: nil)
        sys_id = system.id
        thread = @control.next_thread

        # This performs the actual load of the module
        defer = @thread.defer
        thread.schedule do
            mod = Triggers::Manager.new(thread, ::Orchestrator::Triggers::Module, system)
            defer.resolve mod
        end
        mod = defer.promise.value
        @modules[mod_id] = mod
        defer.resolve(mod) if defer
    rescue => error
        @logger.warn [
            'failed to load trigger',
            error.message,
            error.backtrace&.join("\n")
        ].join("\n")

        # ensure there aren't any expired references
        @modules.delete(system.id)
        defer.resolve(nil) if defer
    end

    def update_state(node_count)
        # These operations block the current fiber
        if node_count > @current_count
            stop_modules
        else
            start_modules
        end

        # Check if this node should be collecting statistics
        if @nodes.is_master_node?
            start_statistics
        else
            stop_statistics
        end
    end

    # Run through all modules and start any that should be running
    def start_modules
        logics = []
        devices = []
        triggers = []

        # Run through all the modules collecting all the devices that should be started
        ::Orchestrator::Module.all.stream do |mod|
            next unless @nodes.running_locally?(mod.id)
            manager = @modules[mod.id]
            next if manager && !manager.is_a?(::Orchestrator::Remote::Manager)

            (mod.role < 3 ? devices : logics) << mod
        end

        # Start all the modules
        [devices, logics].each do |mods|
            mods.each { |mod| load_module(mod.id, mod: mod, run_locally: true) }
        end

        # Triggers are a special case
        ::Orchestrator::ControlSystem.all.stream do |system|
            triggers << system if @nodes.running_locally?(system.id)
        end
        triggers.each { |system| load_trigger(system) }

        # Start everything that was just loaded
        [devices, logics, triggers].each do |mods|
            mods.each do |mod|
                man = @modules[mod.id]
                man.thread.schedule { man.start_local } if man && mod.running
            end
        end
    end

    # Run through loaded modules and stop any that should no longer be running
    def stop_modules
        @modules.keys.each do |mod_id|
            next if @nodes.running_locally?(mod_id)
            manager = @modules[mod_id]
            next if manager.nil? || manager.is_a?(::Orchestrator::Remote::Manager)

            unload_module(mod_id)
        end
    end

    def start_statistics
        next if @statistics
        @statistics = @reactor.scheduler.every('5m') { save_statistics }
        @logger.warn "init: collecting statistics"
    end

    def stop_statistics
        next if @statistics.nil?
        @statistics.cancel
        @statistics = nil
        @logger.warn "stop: collecting statistics"
    end

    def save_statistics
        ::Orchestrator::Stats.new.save
    rescue => error
        @logger.warn [
            'exception saving statistics',
            error.message,
            error.backtrace&.join("\n")
        ].join("\n")
    end

    def sync_sched(error_message, *args)
        @state_mutex.synchronize do
            @thread.schedule do
                retries = 4
                begin
                    yield
                rescue => e
                    retries -= 1
                    retry if retries > 0

                    # If we hit this then we need to wait for the failsafe
                    @logger.error [
                        format(error_message, *args),
                        e.message,
                        e.backtrace&.join("\n")
                    ].join("\n")
                ensure
                    # synchronize is called here to minimize the possibility that
                    # this call to synchronize ever actually blocks anything
                    # purely a structure coordination
                    @state_mutex.synchronize { @state_loaded.broadcast }
                end
            end
            @state_loaded.wait(@state_mutex)
        end
    end
end
