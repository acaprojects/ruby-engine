# frozen_string_literal: true

require File.expand_path("../../helpers", __FILE__)


describe ::Orchestrator::Zone do

    before :each do
        begin
            @zone2 = ::Orchestrator::Zone.new
            @zone2.name = 'trig zone2'
            @zone2.save!

            @edge = ::Orchestrator::EdgeControl.new
            @edge.name = 'edge test'
            @edge.save!

            @cs = ::Orchestrator::ControlSystem.new
            @cs.name = 'trig sys'
            @cs.zones << @zone2.id
            @cs.edge = @edge
            @cs.save!

            @trigger = ::Orchestrator::Trigger.new
            @trigger.name = 'trigger test'
            @trigger.save!

            @zone = ::Orchestrator::Zone.new
            @zone.name = 'trig zone'
            @zone.triggers = [@trigger.id]
            @zone.save!
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
            @zone2.destroy
        rescue
        end
        begin
            @trigger.destroy
        rescue
        end

        @zone = @cs = @trigger = nil
    end

    it "should create triggers when added and removed from a zone" do
        expect(@cs.triggers.to_a.count).to be(0)
        @cs.zones = [@zone2.id, @zone.id]
        @cs.save!

        @cs = ::Orchestrator::ControlSystem.find @cs.id
        expect(@cs.triggers.to_a.count).to be(1)
        expect(@cs.triggers.to_a[0].zone_id).to eq(@zone.id)

        @cs.zones = [@zone2.id]
        @cs.save!

        @cs = ::Orchestrator::ControlSystem.find @cs.id
        expect(@cs.triggers.to_a.count).to be(0)
        expect(@zone.trigger_instances.to_a.count).to be(0)
    end
end
