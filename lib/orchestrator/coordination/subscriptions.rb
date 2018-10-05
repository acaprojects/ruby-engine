# frozen_string_literal: true

require 'set'
require 'json'
require 'thread'
require 'singleton'
require_relative './subscriptions'

module Orchestrator; end
class Orchestrator::Subscriptions
    include Singleton

    Subscription = Struct.new(
        :callback, :json, :status, :sys_name, :sys_id,
        :mod_name, :index, :mod_id, :mod
    )

    def initialize
        @thread = ::Libuv::Reactor.default

        # sys_id => Set of subscriptions
        @systems = {}

        # mod_id => status_name => Subscriptions
        @subscriptions = ::Concurrent::Map.new
        @status_cache = ::Orchestrator::RedisStatus.instance
        @system_cache = ::Orchestrator::SystemCache.instance

        # Updates created on this server to notify subscribers
        @updates = ::Queue.new
        ::Thread.new { local_updates! }
    end

    # Subscriptions come from two locations. Either the websocket or a module
    def subscribe(subscription)
        @thread.schedule { perform_subscribe(subscription) }
    end

    def unsubscribe(subscription)
        @thread.schedule { perform_unsubscribe(subscription) }
    end

    # Module / driver status value has changed
    def update(mod_id, status, value)
        @updates << [mod_id, status, value]
    end

    # Value received from REDIS (always on redis update thread)
    def push(mod_id, status, json_value)
        @subscriptions[mod_id]&.[](status)&.notify(json_value)
    end

    # System cache callback for updating dangling subscriptions
    def reloaded_system(sys_id, system_abstraction)
        @thread.schedule { perform_reload(sys_id, system_abstraction) }
    end

    # TODO:: debugging subscriptions!

    protected

    # The System cache notifies of an update
    def perform_reload(sys_id, sys)
        subscriptions = @systems[sys_id]
        if subscriptions
            check = []
            subscriptions.each do |sub|
                old_id = sub.mod_id
                status = sub.status

                # re-index the subscription
                sys ||= @system_cache.get(sys_id)
                mod = sub.mod = sys.get(sub.mod_name, sub.index)
                mod_id = sub.mod_id = mod ? mod.settings.id : nil

                # Check for changes (order, removal, replacement)
                if old_id != mod_id
                    # remove old subscription
                    if old_id
                        subs = @subscriptions[old_id]&.[](status)
                        if subs
                            if subs.subscriber_count <= 1
                                @subscriptions[old_id].delete(status)
                            else
                                subs.remove(sub.json, sub.callback)
                            end
                        end
                    end

                    perform_subscribe(sub) if mod_id
                end
            end
        end
    end

    def perform_subscribe(sub)
        sys_id = sub.sys_id
        mod_id = sub.mod_id
        status = sub.status

        if sys_id
            # the subscription is abstract
            systems = @systems[sys_id] ||= Set.new
            systems << sub
        end

        if mod_id
            # Mod is passed in to the subscribe method as a performance
            # optimisation as from the websocket we've already performed
            # certain checks and similarly from a module
            mod = sub.mod
            json = sub.json
            callback = sub.callback

            statuses = @subscriptions[mod_id] ||= ::Concurrent::Map.new
            subscribers = statuses[status] ||= Subscribers.new
            subscribers.add(json, callback)

            # check for existing value to send subscription
            # Also needs to handle values in REDIS
            # TODO:: get_status on module manager
            value = mod.get_status(status, json)
            if json
                callback.call(value) unless value == 'null'
            else
                callback.call(value) unless value.nil?
            end
        end
    end

    def perform_unsubscribe(sub)
        sys_id = sub.sys_id
        mod_id = sub.mod_id
        status = sub.status

        # remove generic subscription
        if sys_id
            system = @systems[sys_id]
            if system
                system.delete(sub)
                @systems.delete(sys_id) if system.empty?
            end
        end

        # remove any explicit subscriptions (i.e. the module exists)
        subs = @subscriptions[mod_id]&.[](status)
        if subs
            if subs.subscriber_count <= 1
                @subscriptions[mod_id].delete(status)
            else
                subs.remove(sub.json, sub.callback)
            end
        end
    end

    # All local updates must be converted to JSON as we are going to send them
    # to redis for cluster distribution.
    def local_updates!
        loop do
            retries = 0
            begin
                mod_id, status, value = @updates.pop
                json_value = serialise(mod_id, status, value)

                # Notify redis of the value change
                @status_cache.update(mod_id, status, json_value)

                # Notify any local subscribers
                @subscriptions[mod_id]&.[](status)&.notify(json_value, value)
            rescue Exception => e
                Rails.logger.error [
                    "Error updating status value",
                    e.message,
                    e.backtrace&.join("\n")
                ].join("\n")
                retries += 1
                retry unless retries == 3
            end
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
