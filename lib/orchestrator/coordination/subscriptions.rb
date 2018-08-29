# frozen_string_literal: true

require 'json'
require 'thread'
require 'singleton'

module Orchestrator; end
class Orchestrator::Subscriptions
    include Singleton

    class Subscriptions
        def initialize
            @lock = Mutex.new
            # Coming from a websocket
            @json_subscribers = []
            # Coming from a logic module
            @ruby_subscribers = []
        end

        # minimize the processing required to perform a callback
        def notify(json_value, ruby_value = nil)
            update_ruby = !@ruby_subscribers.empty?
            if update_ruby && ruby_value.nil? && json_value != 'null'
                ruby_value = JSON.parse("[#{json_value}]", symbolize_names: true)[0]
            end

            @lock.synchronize do
                # The subscribers will schedule the update onto their respective event loops
                @json_subscribers.each { |sub| sub.call(json_value) }
                @ruby_subscribers.each { |sub| sub.call(ruby_value) } if update_ruby
            end
        end
    end

    def initialize
        # mod_id => status_name => Subscriptions}
        @subscriptions = ::Concurrent::Map.new
        @cache = ::Orchestrator::RedisStatus.instance

        # Updates created on this server to notify subscribers
        @updates = Queue.new
        Thread.new { local_updates! }
    end

    # TODO:: subscribe and unsubscribe methods
    # System cache mappings for calculating mod_id

    # TODO:: System cache callbacks for updating dangling subscriptions
    def reloaded_system(sys_id, system)
        
    end

    protected

    def local_updates!
        loop do
            mod_id, status, value = @updates.pop
            json_value = serialise(mod_id, status, value)

            # Notify redis of the value change
            @cache.update(mod_id, status, json_value)

            # Notify any local subscribers
            @subscriptions[mod_id]&.[](status)&.notify(json_value, value)
        end
    end

    def serialise(mod_id, status, value)
        [value].to_json[1...-1]
    rescue Exception => e
        Rails.logger.error [
            "unsupported type #{value.class} when converting #{mod_id}->#{status} to json",
            e.message,
            e.backtrace&.join("\n")
        ].join("\n")
        'null'
    end
end
