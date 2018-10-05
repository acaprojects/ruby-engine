# frozen_string_literal: true

require 'json'
require 'thread'
require_relative './subscriptions'

class Orchestrator::Subscriptions::Subscribers
    # We use another thread to ensures minimal locking on a reactor thread.
    @@add_remove = ::Queue.new
    Thread.new do
        loop do
            add, sub, array, lock = @@add_remove.pop
            if add
                lock.synchronize { array << sub }
            else
                lock.synchronize { array.delete(sub) }
            end
        end
    end

    def initialize
        @lock = ::Mutex.new
        # Coming from a websocket
        @json_subscribers = []
        # Coming from a logic module
        @ruby_subscribers = []

        @subscriber_count = 0
    end

    attr_reader :subscriber_count
    def empty?
        @subscriber_count <= 0
    end

    # minimize the processing required to perform a callback
    # this is always called from a dedicated thread (not a reactor thread)
    # see Subscriptions.local_updates!
    def notify(json_value, ruby_value = nil)
        update_ruby = !@ruby_subscribers.empty?
        if update_ruby && ruby_value.nil? && json_value != 'null'
            ruby_value = JSON.parse("[#{json_value}]", symbolize_names: true)[0]
        end

        # This will hold the lock longer than thread that is modifying the
        # arrays to minimize any pausing of event notifications
        @lock.synchronize do
            # The subscribers will schedule the update onto their respective event loops
            @json_subscribers.each { |sub| sub.call(json_value) }

            # Check for update_ruby in case array was updated in the mean time
            @ruby_subscribers.each { |sub| sub.call(ruby_value) } if update_ruby
        end
    end

    # Both add and remove are called from the default reactor thread
    def add(json, callback)
        @subscriber_count += 1
        subscribers = json ? @json_subscribers : @ruby_subscribers
        @@add_remove << [true, callback, subscribers, @lock]
    end

    def remove(json, callback)
        @subscriber_count -= 1
        subscribers = json ? @json_subscribers : @ruby_subscribers
        @@add_remove << [false, callback, subscribers, @lock]
    end
end
