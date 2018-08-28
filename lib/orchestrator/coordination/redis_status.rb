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

        # Ignore updates coming from this server
        @server_id = SecureRandom.hex

        # Start processing the data going in and out of redis
        Thread.new { process_updates! }
        Thread.new { notify_updates! }
    end

    def update(mod_id, status, value)
        @writes << ["#{mod_id}\x2#{status}", value]
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
                        begin
                            # TODO:: push the json value to status manager
                        rescue => e
                            Rails.logger.error [
                                "error loading update for #{mod_id} : #{status}",
                                e.message
                            ].join("\n")
                        end
                    end
                end
            end
        rescue Redis::BaseConnectionError => error
            sleep 1
            retry
        end
    end

    def notify_updates!
        while @online do
            begin
                # Operation values should already be in JSON format
                key, value = @writes.pop

                @redis_sig.pipelined do
                    @redis_sig.set key, value
                    @redis_sig.publish(:notify_engine_core, "#{@server_id}\x2#{key}\x2#{value}")
                    @redis_sig.expireat key, 1.year.from_now.to_i
                end
            rescue => e
                Rails.logger.warn "error notifying updates\n#{e.message}"
            end
        end
    end
end
