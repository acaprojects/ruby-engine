require 'rails'
require 'orchestrator'
require File.expand_path("../helpers", __FILE__)

describe Orchestrator::ClusterState do
    before :each do
        @log = []
        @state = ::Orchestrator::ClusterState.instance
    end

    it "should notify the callback when the cluster state is changed" do
        @state.cluster_change do |new_node_count|
            @log << new_node_count
        end
        @state.new_node_list(['127.0.0.1:7200',  '127.0.0.1:7201'], 1234)

        expect(@log).to eq([2])
    end
end
