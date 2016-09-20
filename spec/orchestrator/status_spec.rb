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

    def update_status(track, status, value)
        @status[status.to_sym] = value
        track.update(settings.id, status, value)
    end

    attr_reader   :status
    attr_accessor :settings, :thread
end

class MockSysProxy
    def initialize
        @modules = {}
        @id = "sys_1-#{rand(10..9999)}"
    end

    attr_reader :id, :modules

    def get(mod_name, index)
        mods = @modules[mod_name.to_sym]
        index = index - 1
        raise "bad index #{index}" if index < 0
        return mods[index] if mods
        nil
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
                }
            }

            expect(@log).to eq(['what what', 'change', 'change', 'next'])
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
            }
            
            expect(@log).to eq(['what what'])
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
            }

            expect(@log).to eq(['what what'])
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
                }
            }

            expect(@log).to eq(['what what'])
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

        it "should unsubscribe" do
            expect(@log).to eq([])
            expect(@sub.value).to be(nil)

            @reactor.run { |reactor|
                @status.reloaded_system(@sys.id, @sys)

                @status.update(@sub.mod_id, @sub.status, 'what what')
                expect(@sub.value).to eq('what what')
                expect(@log).to eq(['what what'])

                @controller.loaded[@sub.mod_id] = @mod
                @status.unsubscribe(@sub)

                @status.update(@sub.mod_id, @sub.status, 'change')
                expect(@sub.value).to eq('what what')
                expect(@log).to eq(['what what'])
            }

            expect(@log).to eq(['what what'])
        end
    end


    describe 'system reload' do
        before :each do
            @mod2 = MockModule.new
            @mod3 = MockModule.new

            @sys = MockSysProxy.new
            @sys.add_module(@mod,  :Display)
            @sys.add_module(@mod2, :Display)
            @sys.add_module(@mod3, :Display)

            opts = {
                callback: proc { |sub| @log << sub.value },
                on_thread: reactor,
                mod_name: :Display,
                sys_name: "Some System",
            }

            @sub1 = @status.subscribe(opts.merge({
                sys_id: @sys.id,
                mod_name: :Display,
                index: 1,
                status: :testing
            }))

            @sub2 = @status.subscribe(opts.merge({
                sys_id: @sys.id,
                mod_name: :Display,
                index: 2,
                status: :testing
            }))

            @sub3 = @status.subscribe(opts.merge({
                sys_id: @sys.id,
                mod_name: :Display,
                index: 2,
                status: :other
            }))

            @sub4 = @status.subscribe(opts.merge({
                sys_id: @sys.id,
                mod_name: :Display,
                index: 3,
                status: :testing
            }))

            # This fills out the subscriptions
            # Tested above in indirect module subscriptions
            @status.reloaded_system(@sys.id, @sys)
        end

        it 'should migrate status on system reload as required' do
            expect(@log).to eq([])
            expect(@sub1.value).to be(nil)
            expect(@sub2.value).to be(nil)
            expect(@sub3.value).to be(nil)
            expect(@sub4.value).to be(nil)

            @reactor.run { |reactor|
                @mod.update_status(@status,  :testing, 'sub1')
                @mod2.update_status(@status, :testing, 'sub2')
                @mod2.update_status(@status, :other,   'sub3')
                @mod3.update_status(@status, :testing, 'sub4')

                expect(@log).to eq(['sub1', 'sub2', 'sub3', 'sub4'])

                # Remove 1 display
                expect(@sub4.mod_id).to be(@mod3.settings.id.to_sym)
                @sys.modules[:Display].shift
                expect(@sys.get(:Display, 3)).to be(nil)
                @status.reloaded_system(@sys.id, @sys)

                # Subscription 1 should now have a new status and new mod_id
                expect(@sub1.mod_id).to be(@mod2.settings.id.to_sym)

                # Subscription 4 which was for display 3 should now be inactive
                expect(@status.valid?(@sub4)).to be(:inactive)
                expect(@sub4.mod_id).to be(nil)

                # Status of other displays should have updated
                expect(@log).to eq(['sub1', 'sub2', 'sub3', 'sub4', 'sub2', 'sub4'])

                # Add display back to the system
                @sys.add_module(@mod, :Display)
                @status.reloaded_system(@sys.id, @sys)

                # Subscription 4 which was for display 3 should now be active
                expect(@status.valid?(@sub4)).to be(:active)
                expect(@sub4.mod_id).to be(@mod.settings.id.to_sym)
            }

            expect(@log).to eq(['sub1', 'sub2', 'sub3', 'sub4', 'sub2', 'sub4', 'sub1'])
        end
    end

    # Test for settings transfer between threads
    describe 'system migrate' do
        
    end
end
