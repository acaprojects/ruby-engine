# frozen_string_literal: true

require 'set'
require 'logger'

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
            debug: ::Logger::DEBUG,
            info: ::Logger::INFO,
            warn: ::Logger::WARN,
            error: ::Logger::ERROR,
            fatal: ::Logger::FATAL
        }.freeze
        LEVEL_NAME = LEVEL.invert

        DEFAULT_LEVEL = ::Rails.env.production? ? ::Logger::WARN : ::Logger::INFO

        def initialize(reactor, mod)
            @reactor = reactor
            @progname = mod.id
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
        alias_method :sev_threshold, :level
        alias_method :sev_threshold=, :level=

        def level_name(level)
            LEVEL_NAME[level] || :unknown
        end

        # Add a listener
        def register(listener)
            if listener.nil?
                @logger.error "attempting to add null listener\n#{caller.join("\n")}"
                return
            end
            if listener.is_a? Enumerable
                @listeners.merge(listener)
            else
                @listeners << listener
            end

            @level = ::Logger::DEBUG
        end

        def remove(listener)
            if listener.is_a? Enumerable
                @listeners.subtract(listener)
            else
                @listeners.delete listener
            end

            @level = DEFAULT_LEVEL if @listeners.empty?
        end

        def add(severity, message = nil, progname = nil)
            severity ||= ::Logger::UNKNOWN
            return true if severity < @level
            progname ||= @progname
            if message.nil?
                if block_given?
                    message = yield
                else
                    message = progname
                    progname = @progname
                end
            end
            log(severity, message, progname)
        end

        def <<(message)
            info(message)
        end
       
        def debug(progname = nil)
            return true if ::Logger::DEBUG < @level
            if block_given?
                add(::Logger::DEBUG, nil, progname) { yield }
            else
                add(::Logger::DEBUG, nil, progname)
            end
        end

        def debug?
            @level <= ::Logger::DEBUG
        end

        def info(progname = nil)
            return true if ::Logger::INFO < @level
            if block_given?
                add(::Logger::INFO, nil, progname) { yield }
            else
                add(::Logger::INFO, nil, progname)
            end
        end

        def info?
            @level <= ::Logger::INFO
        end

        def warn(progname = nil)
            if block_given?
                add(::Logger::WARN, nil, progname) { yield }
            else
                add(::Logger::WARN, nil, progname)
            end
        end

        def warn?
            @level <= ::Logger::WARN
        end

        def error(progname = nil)
            if block_given?
                add(::Logger::ERROR, nil, progname) { yield }
            else
                add(::Logger::ERROR, nil, progname)
            end
        end

        def error?
            @level <= ::Logger::ERROR
        end

        def fatal(progname = nil)
            if block_given?
                add(::Logger::FATAL, nil, progname) { yield }
            else
                add(::Logger::FATAL, nil, progname)
            end
        end

        def fatal?
            @level <= ::Logger::FATAL
        end

        def unknown(progname = nil)
            if block_given?
                add(::Logger::UNKNOWN, nil, progname) { yield }
            else
                add(::Logger::UNKNOWN, nil, progname)
            end
        end

        def print_error(e, msg = nil, trace = nil)
            message = String.new(msg || e.message)
            message << "\n#{e.message}" if msg
            message << "\n#{e.backtrace.join("\n")}" if e.respond_to?(:backtrace) && e.backtrace
            message << "\nCaller backtrace:\n#{trace.join("\n")}" if trace
            error(message)
        end

        def close
            warn '`closed` called on logger. no-op'
        end

        def progname=(_)
            warn '`progname=` called on logger. no-op'
        end

        attr_reader :progname

        def datetime_format
            @logger.datetime_format
        end

        def datetime_format=(datetime_format)
            warn '`datetime_format=` called on logger. no-op'
        end


        protected


        if ::Rails.env.production?
            def log(level, msg, progname)
                return print_error(msg) if msg.is_a?(::Exception)
                msg = msg.inspect unless msg.is_a?(::String)

                tags = [@klass, progname]
                user = ::Orchestrator::Control.instance.loaded?(@progname)&.current_user&.id
                msg = "(#{user}) #{msg}" if user

                @reactor.schedule do
                    # Writing to STDOUT is blocking hence doing this in a worker thread
                    # http://nodejs.org/dist/v0.10.26/docs/api/process.html#process_process_stdout
                    if level > ::Logger::INFO
                        # We never write debug or info logs to disk
                        @reactor.work do
                            @logger.tagged(*tags) {
                                @logger.add(level, msg, progname)
                            }
                        end
                    end

                    # Listeners are any attached remote debuggers
                    if @listeners.size > 0
                        lname = level_name(level)
                        @listeners.each do |listener|
                            begin
                                listener.call(@klass, @progname, lname, msg)
                            rescue Exception => e
                                @logger.error "logging to remote #{listener}\n#{e.message}\n#{e.backtrace.join("\n")}"
                            end
                        end
                    end
                end
            end
        else
            def log(level, msg, progname)
                return print_error(msg) if msg.is_a?(::Exception)
                msg = msg.inspect unless msg.is_a?(::String)

                tags = [@klass, progname]
                user = ::Orchestrator::Control.instance.loaded?(@progname)&.current_user&.id
                msg = "(#{user}) #{msg}" if user

                @reactor.schedule do
                    @logger.tagged(*tags) {
                        @logger.add(level, msg, progname)
                    }

                    # Listeners are any attached remote debuggers
                    if @listeners.size > 0
                        lname = level_name(level)
                        @listeners.each do |listener|
                            begin
                                listener.call(@klass, @progname, lname, msg)
                            rescue Exception => e
                                @logger.error "logging to remote #{listener}\n#{e.message}\n#{e.backtrace.join("\n")}"
                            end
                        end
                    end
                end
            end
        end
    end
end
