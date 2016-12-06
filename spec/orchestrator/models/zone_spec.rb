# frozen_string_literal: true

require File.expand_path("../../helpers", __FILE__)


describe ::Orchestrator::Zone do

    before :each do
        begin
            @zone = ::Orchestrator::Zone.new
            @zone.name = 'trig zone'
            @zone.save!

            @edge = ::Orchestrator::EdgeControl.new
            @edge.name = 'edge test'
            @edge.save!

            @cs = ::Orchestrator::ControlSystem.new
            @cs.name = 'trig sys'
            @cs.zones << @zone.id
            @cs.edge = @edge
            @cs.save!

            @trigger = ::Orchestrator::Trigger.new
            @trigger.name = 'trigger test'
            @trigger.save!
        rescue CouchbaseOrm::Error::RecordInvalid => e
            puts "#{e.record.errors.inspect}"
            raise e
        end
    end

    after :each do
        begin
            @cs.destroy
        rescue
        end
        begin
            @edge.destroy
        rescue
        end
        begin
            @zone.destroy
        rescue
        end
        begin
            @trigger.destroy
        rescue
        end

        @zone = @cs = @trigger = nil
    end

    it "should create triggers when added and removed from a zone" do
        expect(@zone.trigger_instances.to_a.count).to be(0)
        expect(@cs.triggers.to_a.count).to be(0)

        @zone.triggers = [@trigger.id]
        expect(@zone.triggers_changed?).to be(true)
        @zone.save

        expect(@cs.triggers.to_a.count).to be(1)
        expect(@cs.triggers.to_a[0].zone_id).to eq(@zone.id)

        # Reload the relationships
        @zone = ::Orchestrator::Zone.find @zone.id
        expect(@zone.trigger_instances.to_a.count).to be(1)
        @zone.triggers = []
        @zone.save

        @zone = ::Orchestrator::Zone.find @zone.id
        expect(@zone.trigger_instances.to_a.count).to be(0)
    end
end
