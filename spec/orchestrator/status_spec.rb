require 'rails'
require 'orchestrator'

class MockController
    def initialize(log)
        @log = log
        @loaded = {}
    end

    def loaded?(mod_id)
        @loaded[mod_id]
    end

    def log_unhandled_exception(e)
        @log << e
    end

    attr_reader :log
    attr_accessor :loaded
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

class MockSysProxy
    def initialize
        @modules = {}
        @id = "sys_1-#{rand(10..9999)}"
    end

    attr_reader :id

    def get(mod_name, index)
        @modules[mod_name.to_sym][index - 1]
    end

    def add_module(mock_module, mod_name)
        @modules[mod_name.to_sym] ||= []
        @modules[mod_name.to_sym] << mock_module
    end
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


# move + transfer
# system reload
describe Orchestrator::Status do
    before :each do
        @log = []
        @controller = MockController.new(@log)
        @status = Orchestrator::Status.new(reactor, @controller)
        @mod = MockModule.new

        @reactor = reactor
        status = @status
        @reactor.instance_eval { @observer = status }
    end


    describe 'direct module subscriptions' do
        before :each do
            @sub = @status.subscribe(
                status: :testing,
                callback: proc { |sub| @log << sub.value },
                on_thread: reactor,
                mod: @mod,
                mod_id: @mod.settings.id.to_sym
            )
        end

        it "should subscribe to module status directly" do
            expect(@log).to eq([])
            expect(@sub.value).to be(nil)

            @reactor.run { |reactor|
                @status.update(@sub.mod_id, @sub.status, 'what what')
                expect(@sub.value).to eq('what what')
                expect(@log).to eq(['what what'])

                @status.update(@sub.mod_id, @sub.status, 'change')
                expect(@sub.value).to eq('change')
                expect(@log).to eq(['what what', 'change'])

                @status.update(@sub.mod_id, @sub.status, 'change', true)
                expect(@sub.value).to eq('change')
                expect(@log).to eq(['what what', 'change', 'change'])

                reactor.next_tick {
                    @status.update(@sub.mod_id, @sub.status, 'next')
                    expect(@sub.value).to eq('next')
                    expect(@log).to eq(['what what', 'change', 'change', 'next'])
                }
            }
        end

        it "should unsubscribe to status when module loaded" do
            expect(@log).to eq([])
            expect(@sub.value).to be(nil)

            @reactor.run { |reactor|
                @status.update(@sub.mod_id, @sub.status, 'what what')
                expect(@sub.value).to eq('what what')
                expect(@log).to eq(['what what'])

                @controller.loaded[@sub.mod_id] = @mod
                @status.unsubscribe(@sub)

                @status.update(@sub.mod_id, @sub.status, 'change')
                expect(@sub.value).to eq('what what')
                expect(@log).to eq(['what what'])

                @status.update(@sub.mod_id, @sub.status, 'change', true)
                expect(@sub.value).to eq('what what')
                expect(@log).to eq(['what what'])
            }
        end

        it "should unsubscribe to status when module not loaded" do
            expect(@log).to eq([])
            expect(@sub.value).to be(nil)

            @reactor.run { |reactor|
                @status.update(@sub.mod_id, @sub.status, 'what what')
                expect(@sub.value).to eq('what what')
                expect(@log).to eq(['what what'])

                @status.unsubscribe(@sub)

                @status.update(@sub.mod_id, @sub.status, 'change')
                expect(@sub.value).to eq('what what')
                expect(@log).to eq(['what what'])
            }
        end

        it "should unsubscribe when buried in a promise response" do
            expect(@log).to eq([])
            expect(@sub.value).to be(nil)

            @reactor.run { |reactor|
                @status.update(@sub.mod_id, @sub.status, 'what what')
                expect(@sub.value).to eq('what what')
                expect(@log).to eq(['what what'])

                pro_sub = ::Libuv::Q::ResolvedPromise.new(reactor, @sub)
                @status.unsubscribe(pro_sub)

                reactor.next_tick {
                    @status.update(@sub.mod_id, @sub.status, 'change')
                    expect(@sub.value).to eq('what what')
                    expect(@log).to eq(['what what'])
                }
            }
        end
    end


    describe 'indirect module subscriptions' do
        before :each do
            @sys = MockSysProxy.new
            @sys.add_module(@mod, :Display)
            @sub = @status.subscribe(
                status: :testing,
                callback: proc { |sub| @log << sub.value },
                on_thread: reactor,

                sys_id: @sys.id,
                sys_name: "Some System",
                mod_name: "Display",
                index: 1
            )
        end

        it "should subscribe to module status indirectly" do
            expect(@log).to eq([])
            expect(@sub.value).to be(nil)

            @reactor.run { |reactor|
                @status.reloaded_system(@sys.id, @sys)

                @status.update(@sub.mod_id, @sub.status, 'what what')
                expect(@sub.value).to eq('what what')
                expect(@log).to eq(['what what'])

                @status.update(@sub.mod_id, @sub.status, 'change')
                expect(@sub.value).to eq('change')
                expect(@log).to eq(['what what', 'change'])

                @status.update(@sub.mod_id, @sub.status, 'change', true)
                expect(@sub.value).to eq('change')
                expect(@log).to eq(['what what', 'change', 'change'])

                reactor.next_tick {
                    @status.update(@sub.mod_id, @sub.status, 'next')
                    expect(@sub.value).to eq('next')
                }
            }

            expect(@log).to eq(['what what', 'change', 'change', 'next'])
        end
    end
end
