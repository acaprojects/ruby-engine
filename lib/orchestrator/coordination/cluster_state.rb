# frozen_string_literal: true

SEED = (ENV['ALLOCATION_SEED'] || 1234).to_i
THIS_NODE = (ENV['THIS_NODE'] || '127.0.0.1:7200')
NODES = (ENV['NODES'] || '127.0.0.1:7200').split(',')

require 'singleton'
require 'concurrent'
require 'clandestined/rendezvous_hash'

module Orchestrator; end
class Orchestrator::ClusterState
    include Singleton

    BOOT_VERSION = "0\x020"

    def initialize
        @rendezvous = nil
        @node_count = 0
        @loaded_count = 0

        @callbacks = []
        @connections = {}

        @cluster_version = BOOT_VERSION
        @server_ready = {} # tracks the loaded servers for a cluster version
        @redis = ::Orchestrator::RedisStatus.instance
        @control = ::Orchestrator::Control.instance

        # Allow other nodes to connect to this server
        bind, port = THIS_NODE.split(':')
        @node_server = ::Remote::Master.new(bind, port.to_i)

        # Ensures strict ordering of callbacks
        @lock = ::Mutex.new
    end

    attr_reader :node_count, :cluster_version

    def new_node_list(nodes, seed)
        @cache = ::Concurrent::Map.new
        @control.reactor.schedule { @control.reset_ready }

        @lock.synchronize do
            @rendezvous = ::Clandestined::RendezvousHash.new(nodes, seed)

            # inform any listeners
            @node_count = nodes.length
            @loaded_count = 0
            if is_master_node?
                old_version = @cluster_version
                @cluster_version = "#{@node_count}\x02#{(Time.now.to_f * 1000).to_i}"
                @server_ready.delete(old_version)
                @server_ready[@cluster_version] = []
                @redis.notify_new_version(@cluster_version)
            end

            # disconnect from remote nodes
            @connections.each |remote, connection|
                connection.close_connection
            end
            @connections = {}

            # re-connect to remote nodes
            @nodes.each_value do |remote_node|
                next if THIS_NODE == remote_node
                host, port = remote_node.split(':')
                @connections[remote_node.id] = ::UV.connect host, port, Remote::Edge, THIS_NODE, remote_node
            end

            @callbacks.each { |callback| callback.call(@node_count) }
        end
    end

    def cluster_change(&callback)
        @lock.synchronize do
            @callbacks << callback
            callback.call(@node_count) if @rendezvous && @node_count > 0
        end
    end

    def server_allocation(module_id)
        @cache[module_id] ||= @rendezvous.find_node module_id
    end

    def running_locally?(module_id)
        server_allocation(module_id) == THIS_NODE
    end

    def is_master_node?
        @rendezvous.nodes.first == THIS_NODE
    end

    # Each server checks in over redis - only the master node executes this
    def server_load_complete(server_id, node_count, cluster_version)
        @lock.synchronize do
            if cluster_version == BOOT_VERSION
                # NOTE:: Temporary check until etcd integration
                return unless node_count == @node_count
                cluster_version = @cluster_version
            else
                return unless is_latest(cluster_version)
            end
            servers = @server_ready[cluster_version] ||= []
            servers << server_id
            check_cluster_ready
        end
    end

    # This is called by the module loader to indicate the state change has
    # been applied.
    def signal_ready(count)
        @lock.synchronize {
            @loaded_count = count
            @servers_ready[@cluster_version] << @redis.server_id
            @redis.notify_load_complete(count) if count == @node_count
            check_cluster_ready
        }
    end

    # Master node sends out a new version for all the nodes to sync
    # the version is checked to ensure it is the latest one, some nodes might
    # still be executing on an old version.
    def notify_cluster_change(version)
        @lock.synchronize {
            # Ensure we are upgrading the cluster state - not applying an old state
            return unless is_latest(version)
            @server_ready.delete(@cluster_version)
            @cluster_version = version
            @server_ready[version] = []

            # check if processing has already completed
            # (this is very unlikely but we want to safe)
            @redis.notify_load_complete(new_count) if new_count == @loaded_count
        }
    end

    def self.server_allocation(module_id)
        ::Orchestrator::ClusterState.instance.server_allocation(module_id)
    end

    def self.running_locally?(module_id)
        ::Orchestrator::ClusterState.instance.running_locally?(module_id)
    end

    protected

    # Always called from within a lock.
    def check_cluster_ready
        if @servers_ready[@cluster_version].length == @node_count
            @redis.notify_cluster_ready(@cluster_version)
            # execute on load callbacks internally
            ::Orchestrator::Cache.instance.clear
            @control.ready_defer.resolve(true)
        end
    end

    def is_latest(version)
        new_count, new_time = version.split("\x02").map(&:to_i)
        old_count, old_time = @cluster_version.split("\x02").map(&:to_i)
        new_time >= old_time ? true : false
    end
end

# Temporary until hound dog is live
Orchestrator::ClusterState.instance.new_node_list(NODES, SEED)
