# frozen_string_literal: true

require 'thread'
require 'singleton'

module Orchestrator; end
class Orchestrator::SystemCache
    include Singleton

    def initialize
        @systems = ::Concurrent::Map.new
        @loading = ::Concurrent::Map.new
        @critical = ::Mutex.new
        @logger = ::Rails.logger
    end

    def get(id)
        @systems[id] || ::Libuv::Reactor.current ? load(id) : blocking_load(id)
    end

    def expire(id)
        @systems.delete(id)
    end

    def reload(id)
        (Libuv::Reactor.current ? load(id) : blocking_load(id)) if @systems[id]
    end

    def clear_cache
        @systems = ::Concurrent::Map.new
    end

    protected

    # Load the system from the database
    def load(id)
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

        # Start loading a system abstraction
        tries = 4
        begin
            sys = ::Orchestrator::ControlSystem.find_by_id(id)

            # System doesn't exist in the database
            if sys.nil?
                @loading.delete id
                wait.resolve(nil)
                return nil
            end

            # We create the abstraction and store it in the cache
            reactor.work { sys.deep_decrypt }.value
            system = ::Orchestrator::SystemAbstraction.new(sys)
            @systems[id] = system
            wait.resolve(system)
            @loading.delete id

            # return the system abstraction
            system
        rescue => error
            # Sleep the current reactor fiber
            if tries >= 0
                reactor.sleep 200
                tries -= 1
                retry
            else
                @logger.error [
                    "System #{id} failed to load. System #{id} may not function properly",
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
    def blocking_load(id)
        tries = 4
        begin
            sys = ::Orchestrator::ControlSystem.find_by_id(id)
            return nil unless sys
            @systems[id] = ::Orchestrator::SystemAbstraction.new(sys)
        rescue => error
            if tries >= 0
                sleep 0.2
                tries -= 1
                retry
            else
                @logger.error [
                    "System #{id} failed to load. System #{id} may not function properly",
                    error.message,
                    error.backtrace&.join("\n")
                ].join("\n")
                raise error
            end
        end
    end
end
