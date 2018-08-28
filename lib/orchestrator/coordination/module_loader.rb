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

        # block this thread until updates are completed on the reactor thread
        @mutex = Mutex.new
        @loading = ConditionVariable.new

        # Current state of the node
        @loaded = {}
        @current_count = 0
        @processing = false
        @logger = Rails.logger

        # Every 10min we want to ensure state as a fail safe
        # The failsafe is ignored if any processing is currently occuring
        @thread = ::Libuv::Reactor.default
        @thread.scheduler.every('10m') do
            next if @processing || !@queue.empty?
            @queue << nil if @state.compare_and_set(nil, @current_count)
        end
        @statistics = nil

        # Start the node
        ::Thread.new { process_changes! }
    end

    private

    def process_changes!
        loop do
            new_count = nil
            retries = 4
            @processing = !@queue.empty?
            @queue.pop
            @processing = true
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
                Rails.logger.error [
                    'error processing cluster state changes',
                    e.message,
                    e.backtrace&.join("\n")
                ].join("\n")
            end
        end
    end

    def update_state(node_count)
        error = nil

        # Coordinate the updating of the state
        @mutex.synchronize do
            @thread.schedule do
                # This synchronize is exectured on a different thread
                @mutex.synchronize do
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
                        # we signal that we've finished processing
                        @loading.broadcast
                    end
                end
            end

            @loading.wait(@mutex)
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
