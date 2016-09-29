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

# Note:: We should be logging the User id in the log
# see: http://pastebin.com/Wrjp8b8e (rails log_tags)
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
        end

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
                if LEVEL[level] >= DEFAULT_LEVEL
                    @reactor.work do
                        @logger.tagged(@klass, @mod_id) {
                            @logger.send(level, msg)
                        }
                    end
                end
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
