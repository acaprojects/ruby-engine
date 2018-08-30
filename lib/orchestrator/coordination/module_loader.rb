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

    private

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

    # This ensures that changes to actively running modules are serialised.
    # NOTE:: This is only tracking what is loaded. Not starting or stopping anything
    def process_changes!
        loop do
            defer, change, mod_id = @queue.pop
            @processing = true

            # individual module change
            if mod_id
                sync_sched('error changing %s, state: %s', mod_id, change) do
                    change ? load_module(mod_id, nil, defer) : unload_module(mod_id, defer)
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
        mod = ::Orchestrator::Module.find(mod_id) unless mod
        local_device = @nodes.running_locally?(mod_id)
        mod = @modules[mod_id]

        if local_device

        else

        end

        if mod && && mod.is_a?(::Orchestrator::Remote::Manager)

            mod = nil
        end

        # We want to load the module
        if mod.nil?

        end
    end

    def unload_module(mod_id, defer = nil)

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
        device = []
        logic = []
        trigger = []
        ::Orchestrator::Module.all.stream do |mod|
            next unless @nodes.running_locally?(mod.id)

        end
    end

    # Run through loaded modules and stop any that should no longer be running
    def stop_modules

    end

    def start_statistics
        @thread.schedule do
            next if @statistics
            @statistics = @reactor.scheduler.every('5m') do
                begin
                    ::Orchestrator::Stats.new.save
                rescue => e
                    @logger.warn [
                        'exception saving statistics',
                        e.message,
                        e.backtrace&.join("\n")
                    ].join("\n")
                end
            end
            @logger.warn "init: collecting statistics"
        end
    end

    def stop_statistics
        @thread.schedule do
            next if @statistics.nil?
            @statistics.cancel
            @statistics = nil
            @logger.warn "stop: collecting statistics"
        end
    end
end
