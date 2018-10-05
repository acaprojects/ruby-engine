# frozen_string_literal: true

require 'securerandom'
require 'singleton'
require 'thread'

require 'redis'
require 'hiredis'

module Orchestrator; end
class Orchestrator::RedisStatus
    include Singleton

    def initialize
        @redis_sig = Redis.new(driver: :hiredis)
        @redis_sub = Redis.new(driver: :hiredis)
        @writes = Queue.new
        @online = true

        @stattrak = ::Orchestrator::Subscriptions.instance

        # Ignore updates coming from this server
        @server_id = SecureRandom.hex

        # Start processing the data going in and out of redis
        Thread.new { process_updates! }
    end

    # This function will always be called from the subscriptions service thread
    # Subscriptions.local_updates!
    def update(mod_id, status, value)
        key = "#{mod_id}\x2#{status}"

        begin
            @redis_sig.pipelined do
                @redis_sig.set key, value
                @redis_sig.publish(:notify_engine_core, "#{@server_id}\x2#{key}\x2#{value}")
                @redis_sig.expireat key, 1.year.from_now.to_i
            end
        rescue => e
            Rails.logger.warn "error notifying updates\n#{e.message}"
        end
    end

    private

    def process_updates!
        begin
            @redis_sub.subscribe(:notify_engine_core) do |on|
                on.message do |_, message|
                    server_id, message, data = message.split("\x2", 3)

                    # ignore messages from this server
                    next if @server_id == server_id

                    case message
                    when 'reload'
                        # TODO:: reload the specified driver
                    else
                        mod_id = message
                        status, json_value = data.split("\x2", 2)
                        # push the json value to status manager
                        @stattrak.push(mod_id, status.to_sym, json_value)
                    end
                end
            end
        rescue Redis::BaseConnectionError => error
            sleep 1
            retry
        end
    end
end
