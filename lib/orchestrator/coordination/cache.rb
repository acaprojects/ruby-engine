# frozen_string_literal: true

require 'thread'

module Orchestrator; end
class Orchestrator::Cache
    def initialize
        @cache = ::Concurrent::Map.new
        @loading = ::Concurrent::Map.new
        @critical = ::Mutex.new
        @logger = ::Rails.logger
    end

    def get(id)
        @cache[id] || ::Libuv::Reactor.current ? load(id) : blocking_load(id)
    end

    def expire(id)
        @cache.delete(id)
    end

    def reload(id)
        (Libuv::Reactor.current ? load(id) : blocking_load(id)) if @cache[id]
    end

    def clear
        @cache = ::Concurrent::Map.new
    end

    protected

    # Load the zone from the database
    def load_helper(error_message, id)
        loading = @loading[id]
        return loading.value if loading

        # Check if we are already loading this abstraction
        wait = nil
        reactor = nil
        @critical.synchronize {
            loading = @loading[id]
            if loading.nil?
                reactor = ::Libuv::Reactor.current
                wait = reactor.defer
                @loading[id] = wait.promise
            end
        }
        return loading.value if loading

        # Start loading a zone abstraction
        tries = 4
        begin
            object = yield
            @cache[id] = object
            wait.resolve(object)
            @loading.delete id

            # return the object
            object
        rescue => error
            # Sleep the current reactor fiber
            if tries >= 0
                reactor.sleep 200
                tries -= 1
                retry
            else
                @logger.error [
                    format(error_message, id),
                    error.message,
                    error.backtrace&.join("\n")
                ].join("\n")
                wait.reject(error)
                @loading.delete id
                raise error
            end
        end
    end

    # This happens less often but it's better than failure
    def blocking_load_helper(error_message, id)
        tries = 4
        begin
            @cache[id] = yield
        rescue => error
            if tries >= 0
                sleep 0.2
                tries -= 1
                retry
            else
                @logger.error [
                    format(error_message, id),
                    error.message,
                    error.backtrace&.join("\n")
                ].join("\n")
                raise error
            end
        end
    end
end
