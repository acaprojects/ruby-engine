# frozen_string_literal: true

require 'set'

# Update the regular logger
class ::Logger
    def print_error(e, msg = nil, trace = nil)
        message = String.new(msg || e.message)
        message << "\n#{e.message}" if msg
        message << "\n#{e.backtrace.join("\n")}" if e.respond_to?(:backtrace) && e.backtrace
        message << "\nCaller backtrace:\n#{trace.join("\n")}" if trace
        error(message)
    end
end

module Orchestrator
    class Logger
        LEVEL = {
            debug: 0,
            info: 1,
            warn: 2,
            error: 3,
            fatal: 4
        }.freeze

        # TODO:: Make this a config item
        DEFAULT_LEVEL = 1

        def initialize(reactor, mod)
            @reactor = reactor
            @mod_id = mod.id
            if mod.respond_to? :dependency
                @klass = mod.dependency.class_name
            elsif mod.respond_to? :control_system_id
                @klass = 'Triggers'
            else
                @klass = 'User' # Filter by user driven events and behavior
            end
            @level = DEFAULT_LEVEL
            @listeners = Set.new
            @logger = ::Orchestrator::Control.instance.logger

            @use_blocking_writes = false
        end

        attr_accessor :use_blocking_writes


        def level=(level)
            @level = LEVEL[level] || level
        end
        attr_reader :level

        # Add listener
        def add(listener)
            if listener.nil?
                @logger.error "attempting to add null listener\n#{caller.join("\n")}"
                return
            end
            if listener.is_a? Enumerable
                @listeners.merge(listener)
            else
                @listeners << listener
            end

            @level = 0
        end

        def remove(listener)
            if listener.is_a? Enumerable
                @listeners.subtract(listener)
            else
                @listeners.delete listener
            end

            @level = DEFAULT_LEVEL if @listeners.empty?
        end

       
        def debug(msg = nil)
            if @level <= 0
                msg = yield if msg.nil? && block_given?
                log(:debug, msg)
            end
        end

        def info(msg = nil)
            if @level <= 1
                msg = yield if msg.nil? && block_given?
                log(:info, msg)
            end
        end

        def warn(msg = nil)
            if @level <= 2
                msg = yield if msg.nil? && block_given?
                log(:warn, msg)
            end
        end

        def error(msg = nil)
            if @level <= 3
                msg = yield if msg.nil? && block_given?
                log(:error, msg)
            end
        end

        def fatal(msg = nil)
            if @level <= 4
                msg = yield if msg.nil? && block_given?
                log(:fatal, msg)
            end
        end

        def print_error(e, msg = nil, trace = nil)
            message = String.new(msg || e.message)
            message << "\n#{e.message}" if msg
            message << "\n#{e.backtrace.join("\n")}" if e.respond_to?(:backtrace) && e.backtrace
            message << "\nCaller backtrace:\n#{trace.join("\n")}" if trace
            error(message)
        end


        protected


        def log(level, msg)
            @reactor.schedule do
                tags = [@klass, @mod_id]

                mod = ::Orchestrator::Control.instance.loaded?(@mod_id)
                tags << mod.current_user.id if mod && mod.current_user

                # Writing to STDOUT is blocking hence doing this in a worker thread
                # http://nodejs.org/dist/v0.10.26/docs/api/process.html#process_process_stdout
                if @use_blocking_writes
                    @logger.tagged(*tags) {
                        @logger.send(level, msg)
                    }
                elsif level >= DEFAULT_LEVEL
                    # We never write debug logs to the main log
                    @reactor.work do
                        @logger.tagged(*tags) {
                            @logger.send(level, msg)
                        }
                    end
                end

                # Listeners are any attached remote debuggers
                @listeners.each do |listener|
                    begin
                        listener.call(@klass, @mod_id, level, msg)
                    rescue Exception => e
                        @logger.error "logging to remote #{listener}\n#{e.message}\n#{e.backtrace.join("\n")}"
                    end
                end
            end
        end
    end
end
