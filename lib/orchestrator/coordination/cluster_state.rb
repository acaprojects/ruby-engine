# frozen_string_literal: true

SEED = (ENV['ALLOCATION_SEED'] || 1234).to_i
THIS_NODE = (ENV['THIS_NODE'] || '127.0.0.1')
NODES = (ENV['NODES'] || '127.0.0.1').split(',')

require 'singleton'
require 'concurrent'
require 'clandestined/rendezvous_hash'

module Orchestrator; end
class Orchestrator::ClusterState
    include Singleton

    def initialize
        @rendezvous = nil
        @callbacks = []

        # Ensures strict ordering of callbacks
        @lock = Mutex.new
    end

    def new_node_list(nodes, seed)
        @cache = ::Concurrent::Map.new

        @lock.synchronize do
            @rendezvous = ::Clandestined::RendezvousHash.new(nodes, seed)

            # inform any listeners
            count = nodes.length
            @callbacks.each { |callback| callback.call(count) }
        end
    end

    def cluster_change(&callback)
        @lock.synchronize do
            @callbacks << callback
            callback.call(@rendezvous.nodes.length) if @rendezvous
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

    def self.server_allocation(module_id)
        ::Orchestrator::ClusterState.instance.server_allocation(module_id)
    end

    def self.running_locally?(module_id)
        ::Orchestrator::ClusterState.instance.running_locally?(module_id)
    end
end

# Temporary until hound dog is live
Orchestrator::ClusterState.instance.new_node_list(NODES, SEED)
