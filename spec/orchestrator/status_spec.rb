require 'rails'
require 'orchestrator'

class MockController
    def initialize(log)
        @log = log
    end

    def loaded?(mod_id)

    end

    def log_unhandled_exception(e)
        @log << e
    end

    attr_reader :log
end

class MockModule
    def initialize(status = {})
        @status = status
        @thread = reactor
        @settings = OpenStruct.new
        @settings.id = "mod_1-#{rand(10..9999)}"
    end

    attr_reader   :status
    attr_accessor :settings, :thread
end

describe Orchestrator::Subscription do
    before :each do
        @reactor = reactor
        @log = []
        @sub = Orchestrator::Subscription.new
        @sub.on_thread = @reactor
        @sub.callback = proc { |sub|
            @log << sub.value
        }
    end


    it "should notify the callback when a value is updated" do
        @reactor.run { |reactor|
            @sub.notify('test')
            reactor.next_tick {
                @sub.notify('next')
                reactor.next_tick {
                    @sub.notify('next')
                }
            }
        }

        expect(@log).to eq(['test', 'next'])
    end

    it "should notify when a value is force updated" do
        @reactor.run { |reactor|
            @sub.notify('test')
            reactor.next_tick {
                @sub.notify('next')
                reactor.next_tick {
                    @sub.notify('next', true)
                }
            }
        }

        expect(@log).to eq(['test', 'next', 'next'])
    end

    it "should have a subscription id" do
        expect(@sub.sub_id).to be > 1
        sub = Orchestrator::Subscription.new
        expect(sub.sub_id).to be > @sub.sub_id
    end
end


# subscribe + unsubscribe
# move + transfer
# system reload
describe Orchestrator::Status do
    before :each do
        @log = []
        @controller = MockController.new(@log)
        @status = Orchestrator::Status.new(reactor, @controller)
        @mod = MockModule.new
    end


    describe 'module subscription' do
        before :each do
            @sub = @status.subscribe(status: :testing, callback: proc { |sub| @log << sub.value }, on_thread: reactor, mod: @mod, mod_id: @mod.settings.id.to_sym)
        end

        it "should subscribe to modules directly" do
            expect(@log).to eq([])
            expect(@sub.value).to be(nil)

            reactor.run { |reactor|
                @status.update(@sub.mod_id, @sub.status, 'what what')
                expect(@sub.value).to eq('what what')
                expect(@log).to eq(['what what'])

                @status.update(@sub.mod_id, @sub.status, 'change')
                expect(@sub.value).to eq('change')
                expect(@log).to eq(['what what', 'change'])

                @status.update(@sub.mod_id, @sub.status, 'change', true)
                expect(@sub.value).to eq('change')
                expect(@log).to eq(['what what', 'change', 'change'])
            }
        end

    end
end
