require 'rails'
require 'orchestrator'
require File.expand_path("../helpers", __FILE__)

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

        expect(@reactor.observer).to be(@status)
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

            @controller.loaded = {}
            @controller.add(@mod)
            @controller.add(@mod2)
            @controller.add(@mod3)

            opts = {
                callback: proc { |sub|
                    @log << sub.value
                    if sub.value.nil?
                        puts caller.join("\n")
                    end
                },
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

                # Subscription 4 which is now for display 1 should now be active
                expect(@status.valid?(@sub4)).to be(:active)
                expect(@sub4.mod_id).to be(@mod.settings.id.to_sym)
            }

            expect(@log).to eq(['sub1', 'sub2', 'sub3', 'sub4', 'sub2', 'sub4', 'sub1'])
        end

        it 'should migrate modules accross threads' do
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

                # Move modules to a new thread
                reactor2 = ::Libuv::Reactor.new
                status2 = Orchestrator::Status.new(reactor2, @controller)
                status2.reloaded_system(@sys.id, @sys)

                reactor2.instance_eval { @observer = status2 }
                @mod2.thread = reactor2
                
                @status.reloaded_system(@sys.id, @sys)

                # Proccess scheduled events
                thread = Thread.new do
                    reactor2.run { |reactor|
                        reactor.next_tick do
                            reactor.next_tick do
                                reactor.next_tick do
                                    status2.reloaded_system(@sys.id, @sys)
                                end
                            end
                        end
                    }
                end
                thread.join

                # Next tick as thread join above would have paused the reactor thread
                reactor.next_tick do
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

                    # Subscription 4 which is now for display 1 should now be active
                    expect(@status.valid?(@sub4)).to be(:active)
                    expect(@sub4.mod_id).to be(@mod.settings.id.to_sym)

                    # -----------------------------------------

                    # Confirm subscriptions have changed thread
                    expect(@status.valid?(@sub1)).to be(false)
                    expect(@status.valid?(@sub1)).to be(false)
                    expect(status2.valid?(@sub1)).to be(:active)
                    expect(status2.valid?(@sub1)).to be(:active)
                end
            }

            expect(@log).to eq(['sub1', 'sub2', 'sub3', 'sub4', 'sub2', 'sub4', 'sub1'])
        end
    end

    describe 'debugging subscriptions' do
        it 'should subscribe to module if it has not been loaded' do
            callbacks = @status.check_debug 'some_id'
            expect(callbacks).to be(nil)

            @reactor.run { |reactor|
                callback = @status.debug_subscribe('some_id', proc { })
                callbacks = @status.check_debug 'some_id'

                expect(callbacks.class).to be(Set)
                expect(callbacks.size).to be(1)
                expect(callbacks.include?(callback)).to be(true)

                @status.debug_unsubscribe('some_id', callback)
                expect(callbacks.empty?).to be(true)
                callbacks = @status.check_debug 'some_id'
                expect(callbacks).to be(nil)
            }
        end

        it 'should subscribe to module if it has been loaded' do
            callbacks = @status.check_debug @mod.settings.id
            expect(callbacks).to be(nil)

            @controller.loaded = {}
            @controller.add(@mod)

            @reactor.run { |reactor|
                callback = @status.debug_subscribe(@mod.settings.id, proc { })
                callbacks = @status.check_debug @mod.settings.id

                expect(callbacks.class).to be(Set)
                expect(callbacks.size).to be(1)
                expect(callbacks.include?(callback)).to be(true)

                expect(@mod.logger.listeners.size).to be(1)
                expect(@mod.logger.listeners.include?(callback)).to be(true)

                @status.debug_unsubscribe(@mod.settings.id, callback)
                expect(callbacks.empty?).to be(true)
                callbacks = @status.check_debug @mod.settings.id
                expect(callbacks).to be(nil)

                expect(@mod.logger.listeners.size).to be(0)
            }
        end

        it 'should subscribe to module when it loads if a subscription is pending' do
            callbacks = @status.check_debug @mod.settings.id
            expect(callbacks).to be(nil)

            @reactor.run { |reactor|
                callback = @status.debug_subscribe(@mod.settings.id, proc { })
                callbacks = @status.check_debug @mod.settings.id

                expect(callbacks.class).to be(Set)
                expect(callbacks.size).to be(1)
                expect(callbacks.include?(callback)).to be(true)

                expect(@mod.logger.listeners.size).to be(0)
                expect(@mod.logger.listeners.include?(callback)).to be(false)

                @controller.loaded = {}
                @controller.add(@mod)
                # This is called when a module is loaded
                @status.move(@mod.settings.id, reactor)

                expect(@mod.logger.listeners.size).to be(1)
                expect(@mod.logger.listeners.include?(callback)).to be(true)
            }
        end
    end
end
