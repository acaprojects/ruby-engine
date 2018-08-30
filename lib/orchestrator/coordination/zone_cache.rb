# frozen_string_literal: true

require 'thread'
require 'singleton'

module Orchestrator; end
class Orchestrator::ZoneCache
    include Singleton

    def initialize
        @zones = ::Concurrent::Map.new
        @loading = ::Concurrent::Map.new
        @critical = ::Mutex.new
        @logger = ::Rails.logger
    end

    def get(id)
        @zones[id] || ::Libuv::Reactor.current ? load(id) : blocking_load(id)
    end

    def delete(id)
        @zones.delete(id)
    end

    def reload(id)
        (Libuv::Reactor.current ? load(id) : blocking_load(id)) if @zones[id]
    end

    def clear_cache
        @zones = ::Concurrent::Map.new
    end

    protected

    # Load the zone from the database
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

        # Start loading a zone abstraction
        tries = 4
        begin
            zone = ::Orchestrator::Zone.find_by_id(id)

            # Zone doesn't exist in the database
            if zone.nil?
                @loading.delete id
                wait.resolve(nil)
                return nil
            end

            # We create the abstraction and store it in the cache
            reactor.work { zone.deep_decrypt }.value
            @zones[id] = zone
            wait.resolve(zone)
            @loading.delete id

            # return the zone
            zone
        rescue => error
            # Sleep the current reactor fiber
            if tries >= 0
                reactor.sleep 200
                tries -= 1
                retry
            else
                @logger.error [
                    "Zone #{id} failed to load.",
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
            zone = ::Orchestrator::Zone.find_by_id(id)
            zone.deep_decrypt
            @zones[id] = zone
        rescue => error
            if tries >= 0
                sleep 0.2
                tries -= 1
                retry
            else
                @logger.error [
                    "Zone #{id} failed to load.",
                    error.message,
                    error.backtrace&.join("\n")
                ].join("\n")
                raise error
            end
        end
    end
end
