# frozen_string_literal: true

require 'rails'
require 'orchestrator'

describe "trigger state" do
    MockTrig = Struct.new(:id, :triggered, :conditions, :override)
    MockStat = Struct.new(:mod_name, :index, :status, :val) do
        def value
            val
        end
    end

    before :each do
        @sched = ::Libuv::Reactor.default.scheduler
        @result = nil
        @trig = MockTrig.new("test", false)
        @trig.override = {}
        @callback = proc do |name, new_state|
            @result = new_state
        end
    end

    it "should work with a single condition" do
        
        @trig.conditions = [[{
            mod: :Display,
            index: 1,
            status: :power
        }, :equal, {
            const: true
        }]]

        state = ::Orchestrator::Triggers::State.new(@trig, @sched, @callback)
        
        state.set_value MockStat.new(:Display, 1, :power, true)

        expect(@result).to eq(nil)
        expect(state.triggered).to eq(false)

        state.enabled(true)
        expect(@result).to eq(true)
        expect(state.triggered).to eq(true)

        state.set_value MockStat.new(:Display, 1, :power, false)
        expect(@result).to eq(false)
        expect(state.triggered).to eq(false)

        state.enabled(false)

        state.set_value MockStat.new(:Display, 1, :power, true)
        expect(@result).to eq(false)
        expect(state.triggered).to eq(false)

        state.enabled(true)
        expect(@result).to eq(true)
        expect(state.triggered).to eq(true)
    end

    it "should work with multiple conditions" do
        @trig.conditions = [[{
            mod: :Display,
            index: 1,
            status: :lamp_hours
        }, :greater_than, {
            const: 200
        }], [{
            mod: :Display,
            index: 1,
            status: :power
        }, :equal, {
            const: true
        }]]

        state = ::Orchestrator::Triggers::State.new(@trig, @sched, @callback)

        state.set_value MockStat.new(:Display, 1, :lamp_hours, 300)
        state.set_value MockStat.new(:Display, 1, :power, true)

        state.enabled(true)

        expect(@result).to eq(true)
        expect(state.triggered).to eq(true)

        state.set_value MockStat.new(:Display, 1, :lamp_hours, 0)

        expect(@result).to eq(false)
        expect(state.triggered).to eq(false)
    end

    it "should work with subkeys of a value" do
        @trig.conditions = [[{
            mod: :Display,
            index: 1,
            status: :running_time,
            keys: [:lamp, :hours]
        }, :greater_than, {
            const: 200
        }]]

        state = ::Orchestrator::Triggers::State.new(@trig, @sched, @callback)
        state.set_value MockStat.new(:Display, 1, :running_time, {lamp: {hours: 300}})
        state.enabled(true)

        expect(@result).to eq(true)
        expect(state.triggered).to eq(true)

        state.set_value MockStat.new(:Display, 1, :running_time, {lamp: {hours: 0}})

        expect(@result).to eq(false)
        expect(state.triggered).to eq(false)
    end

    it "should return nil for subkeys of a value that don't exist" do
        @trig.conditions = [[{
            mod: :Display,
            index: 1,
            status: :running_time,
            keys: [:lamp, :hours]
        }, :greater_than, {
            const: 200
        }]]

        state = ::Orchestrator::Triggers::State.new(@trig, @sched, @callback)
        state.set_value MockStat.new(:Display, 1, :running_time, {lamp: nil})
        state.enabled(true)

        expect(@result).to eq(nil)
        expect(state.triggered).to eq(false)

        state.set_value MockStat.new(:Display, 1, :running_time, {lamp: {}})

        expect(@result).to eq(nil)
        expect(state.triggered).to eq(false)

        state.set_value MockStat.new(:Display, 1, :running_time, {lamp: {hours: 300}})

        expect(@result).to eq(true)
        expect(state.triggered).to eq(true)
    end

    it "should return a list of values to subscribe to" do
        @trig.conditions = [[{
            mod: :Display,
            index: 1,
            status: :lamp_hours
        }, :greater_than, {
            mod: :Display,
            index: 1,
            status: :max_hours,
            keys: [:lamp, :hours]
        }], [{
            mod: :Display,
            index: 1,
            status: :power
        }, :equal, {
            const: true
        }], [{
            mod: :Display,
            index: 1,
            status: :lamp_hours
        }, :greater_than, {
            const: 100
        }]]

        state = ::Orchestrator::Triggers::State.new(@trig, @sched, @callback)

        expect(state.subscriptions).to eq([
            {
                mod: :Display,
                index: 1,
                status: :lamp_hours
            },
            {
                mod: :Display,
                index: 1,
                status: :max_hours,
                keys: [:lamp, :hours]
            },
            {
                mod: :Display,
                index: 1,
                status: :power
            }
        ])
    end

    it "should be possible to override condition values" do
        @trig.conditions = [[{
            mod: :Display,
            index: 1,
            status: :lamp_hours
        }, :greater_than, {
            value_id: 1,
            const: 200
        }], [{
            mod: :Display,
            index: 1,
            status: :power
        }, :equal, {
            const: true
        }]]

        @trig.override = {
            1 => {
                const: 300
            }
        }

        state = ::Orchestrator::Triggers::State.new(@trig, @sched, @callback)

        state.set_value MockStat.new(:Display, 1, :lamp_hours, 300)
        state.set_value MockStat.new(:Display, 1, :power, true)

        state.enabled(true)

        expect(@result).to eq(nil)
        expect(state.triggered).to eq(false)

        state.set_value MockStat.new(:Display, 1, :lamp_hours, 350)

        expect(@result).to eq(true)
        expect(state.triggered).to eq(true)
    end

    it "should work with one time events" do

    end

    it "should work with cron events" do

    end
end
