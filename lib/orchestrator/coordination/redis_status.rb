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

    attr_reader :server_id

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

    # Master node signals new cluster versions (nodes need to check-in)
    def notify_new_version(version)
        @redis_sig.publish(:notify_engine_core, "#{@server_id}\x2new_version\x2#{version}")
    end

    # Master node signals once all servers have checked in
    def notify_cluster_ready(version)
        @redis_sig.publish(:notify_engine_core, "#{@server_id}\x2#{cluster_ready}\x2#{version}")
    end

    # Each server notifies when their modules have loaded
    def notify_load_complete(node_count, cluster_version)
        @redis_sig.publish(:notify_engine_core, "#{@server_id}\x2#{load_complete}\x2#{node_count}\x2#{cluster_version}")
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
                        # TODO:: reload the specified dependency
                    when 'start'
                        # TODO:: start the specified module
                    when 'stop'
                        # TODO:: stop the specified modules
                    when 'unload'
                        # TODO:: unload the specified module as it's been deleted
                    when 'update'
                        # TODO:: new settings are available
                    when 'expire_cache'
                        # TODO:: reset a systems cache
                    when 'new_version'
                        # This requests that the current node check in once
                        # any changes to the current node are complete
                        ::Orchestrator::ClusterState.instance.notify_cluster_change(data)
                    when 'cluster_ready'
                        # This occurs once the cluster is ready to start
                        # processing and module callbacks should be executed
                        # Also clears all the system caches
                        ::Orchestrator::Cache.instance.clear
                        ::Orchestrator::Control.instance.ready_promise.resolve(true)
                    when 'load_complete'
                        # This is a signal to the master server to indicate
                        # a server has has completed loading
                        ::Orchestrator::ClusterState.instance.server_load_complete(server_id, *data.split("\x2", 2))
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
