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

    # This ensures that load changes are serialised.
    # NOTE:: This is only tracking what is loaded. Not start or stopped state
    def process_changes!
        loop do
            defer, change, mod_id = @queue.pop
            @processing = true

            if mod_id
                retries = 4
                begin
                    mod = ::Orchestrator::Module.find mod_id
                    change ? load_module(mod_id, defer) : unload_module(mod_id, defer)
                rescue => e
                    retries -= 1
                    retry if retries > 0

                    # If we hit this then we need to wait for the failsafe
                    @logger.error [
                        "error changing state #{change}",
                        e.message,
                        e.backtrace&.join("\n")
                    ].join("\n")
                end
            else
                cluster_state_changed
            end

            @processing = !@queue.empty?
        end
    end

    def cluster_state_changed
        new_count = nil
        retries = 4
        begin
            # We might be retrying so new_count might not be nil
            new_count = @state.get_and_set(nil) || new_count
            if new_count
                update_state(new_count)
                @current_count = new_count
                new_count = nil
            end
            @nodes.signal_ready(@current_count) if @queue.empty?
        rescue => e
            retries -= 1
            retry if retries > 0

            # If we hit this then we need to wait for the failsafe
            @logger.error [
                'error processing cluster state changes',
                e.message,
                e.backtrace&.join("\n")
            ].join("\n")
        end
    end

    def update_state(node_count)
        error = nil

        # Coordinate the updating of the state
        @state_mutex.synchronize do
            @thread.schedule do
                begin
                    # These operations block the current fiber
                    if node_count > @current_count
                        stop_modules
                    else
                        start_modules
                    end
                rescue => e
                    # save the error for raising later
                    error = e
                ensure
                    # This synchronize is exectured on a different thread
                    # we signal that we've finished processing
                    # synchronize is called here to minimize the possibility that
                    # this call to synchronize ever actually blocks anything
                    @state_mutex.synchronize { @state_loaded.broadcast }
                end
            end
            @state_loaded.wait(@state_mutex)
        end

        raise error if error

        # Check if this node should be collecting statistics
        if @nodes.is_master_node?
            start_statistics
        else
            stop_statistics
        end
    end

    # Run through all modules and start any that should be running
    def start_modules
        load = []
        ::Orchestrator::Module.all.stream do |mod|
            load << mod.id if @nodes.running_locally?(mod.id)
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
