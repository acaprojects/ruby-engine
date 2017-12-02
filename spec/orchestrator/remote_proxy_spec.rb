require 'rails'
require 'orchestrator'
require File.expand_path("../helpers", __FILE__)


class MockCtrl
    def initialize(logger, do_fail = false)
        @log = logger
        @do_fail = do_fail
    end

    def start(mod, remote = true)
        defer = ::Libuv.reactor.defer
        @log << [:start, mod, remote]
        @do_fail ? defer.reject(false) : defer.resolve(true)
        defer.promise
    end

    def stop(mod, remote = true)
        defer = ::Libuv.reactor.defer
        @log << [:stop, mod, remote]
        @do_fail ? defer.reject(false) : defer.resolve(true)
        defer.promise
    end

    def unload(mod, remote = true)
        defer = ::Libuv.reactor.defer
        @log << [:unload, mod, remote]
        @do_fail ? defer.reject(false) : defer.resolve(true)
        defer.promise
    end

    def loaded?(mod_name)
        self unless @do_fail
    end

    def update(mod, remote = true)
        defer = ::Libuv.reactor.defer
        @log << [:update, mod, remote]
        @do_fail ? defer.reject(false) : defer.resolve(true)
        defer.promise
    end

    def expire_cache(sys, remote = true, no_update: nil)
        @log << [:expire_cache, sys, remote]
    end

    def reactor
        ::Libuv.reactor
    end

    def running
        true
    end

    def reloaded(settings)
        @log << settings
    end

    # ==========
    # debug logging mocks
    # ==========
    def logger
        self
    end

    def register(callback)
        @cb = callback
        @log << :registered
    end

    def remove(callback)
        @log << :removed if @cb == callback
        @cb = nil
    end

    def log(message)
        @cb.call('MockCtrl', 'mod_111', :info, message)
    end

    # ===============
    # This is emulating a module manager for status requests
    # ===============
    def status
        {
            connected: true
        }
    end

    def trak(status, val, remote = true)
        @log << [status, val, remote]
        val
    end

    # ===============
    # This is technically the dependency manager
    # ===============
    def load(dependency, force = false)
        defer = ::Libuv.reactor.defer
        classname = dependency.class_name
        class_object = classname.constantize

        defer.resolve(class_object)
        defer.promise
    end

    # this is technically the TCP object
    def write(data)
        written = Marshal.load(data)
        @log << written
        ::Libuv::Q::ResolvedPromise.new(::Libuv.reactor, written)
    end

    def finally
    end
end


describe Orchestrator::Remote::Proxy do
    before :each do
        @reactor = ::Libuv::Reactor.default
        @log = []
    end

    it "should send an execute request" do
        failed = true
        @reactor.run do
            mock = MockCtrl.new(@log, true)
            proxy = ::Orchestrator::Remote::Proxy.new(mock, mock, mock)

            # Create request
            req = proxy.execute('mod_111', 'function', [1,2,3])
            sent = ::Orchestrator::Remote::Request.new(
                :cmd,
                'mod_111',
                'function',
                [1,2,3],
                nil,
                1
            )
            expect(@log[0]).to eq(sent)

            # Process request
            proxy.process(@log[0])
            expect(@log[1].id).to eq(1)
            expect(@log[1].type).to eq(:reject)
            expect(@log[1].value).to eq('module not loaded')

            # Process response
            proxy.process(@log[1])
            req.catch do |error|
                failed = false
            end
        end

        expect(failed).to be(false)
    end

    it "should send a status lookup request" do
        failed = true
        @reactor.run do
            mock = MockCtrl.new(@log)
            proxy = ::Orchestrator::Remote::Proxy.new(mock, mock, mock)

            # Create request
            req = proxy.status('mod_111', 'connected')
            sent = ::Orchestrator::Remote::Request.new(
                :stat,
                'mod_111',
                'connected',
                nil,
                nil,
                1
            )
            expect(@log[0]).to eq(sent)

            # Process request
            proxy.process(@log[0])
            expect(@log[1].id).to eq(1)
            expect(@log[1].type).to eq(:resolve)
            expect(@log[1].value).to eq(true)

            # Process response
            proxy.process(@log[1])
            req.then do |resp|
                failed = resp != true
            end
        end

        expect(failed).to be(false)
    end

    it "should send a set status request" do
        failed = true
        @reactor.run do
            mock = MockCtrl.new(@log)
            proxy = ::Orchestrator::Remote::Proxy.new(mock, mock, mock)

            # Create request
            req = proxy.set_status('mod_111', :new_status, 'value')
            sent = ::Orchestrator::Remote::Request.new(
                :push,
                'mod_111',
                :status,
                [:new_status, 'value'],
                nil,
                1
            )
            expect(@log[0]).to eq(sent)

            # Process request
            proxy.process(@log[0])
            expect(@log[1]).to eq([:new_status, 'value', false])

            expect(@log[2].id).to eq(1)
            expect(@log[2].type).to eq(:resolve)
            expect(@log[2].value).to eq(true)

            # Process response
            proxy.process(@log[2])
            req.then do |resp|
                failed = resp != true
            end
        end

        expect(failed).to be(false)
    end

    it "should send a start module request" do
        failed = true
        @reactor.run do
            mock = MockCtrl.new(@log)
            proxy = ::Orchestrator::Remote::Proxy.new(mock, mock, mock)

            # Create request
            req = proxy.start('mod_111')
            sent = ::Orchestrator::Remote::Request.new(
                :push,
                'mod_111',
                :start,
                nil,
                nil,
                1
            )
            expect(@log[0]).to eq(sent)

            # Process request
            proxy.process(@log[0])
            @reactor.next_tick do
                expect(@log[1]).to eq([:start, 'mod_111', false])

                expect(@log[2].id).to eq(1)
                expect(@log[2].type).to eq(:resolve)
                expect(@log[2].value).to eq(true)

                # Process response
                proxy.process(@log[2])
                req.then do |resp|
                    failed = resp != true
                end
            end
        end

        expect(failed).to be(false)
    end

    it "should send a stop module request" do
        failed = true
        @reactor.run do
            mock = MockCtrl.new(@log)
            proxy = ::Orchestrator::Remote::Proxy.new(mock, mock, mock)

            # Create request
            req = proxy.stop('mod_111')
            sent = ::Orchestrator::Remote::Request.new(
                :push,
                'mod_111',
                :stop,
                nil,
                nil,
                1
            )
            expect(@log[0]).to eq(sent)

            # Process request
            proxy.process(@log[0])
            @reactor.next_tick do
                expect(@log[1]).to eq([:stop, 'mod_111', false])

                expect(@log[2].id).to eq(1)
                expect(@log[2].type).to eq(:resolve)
                expect(@log[2].value).to eq(true)

                # Process response
                proxy.process(@log[2])
                req.then do |resp|
                    failed = resp != true
                end
            end
        end

        expect(failed).to be(false)
    end

    it "should send a load module request" do
        failed = true
        @reactor.run do
            mock = MockCtrl.new(@log)
            proxy = ::Orchestrator::Remote::Proxy.new(mock, mock, mock)

            # Create request
            req = proxy.load('mod_111')
            sent = ::Orchestrator::Remote::Request.new(
                :push,
                'mod_111',
                :load,
                nil,
                nil,
                1
            )
            expect(@log[0]).to eq(sent)

            # Process request
            proxy.process(@log[0])
            @reactor.next_tick do
                expect(@log[1]).to eq([:update, 'mod_111', false])

                expect(@log[2].id).to eq(1)
                expect(@log[2].type).to eq(:resolve)
                expect(@log[2].value).to eq(true)

                # Process response
                proxy.process(@log[2])
                req.then do |resp|
                    failed = resp != true
                end
            end
        end

        expect(failed).to be(false)
    end

    it "should check if the module is running on the remote node" do
        failed = true
        @reactor.run do
            mock = MockCtrl.new(@log)
            proxy = ::Orchestrator::Remote::Proxy.new(mock, mock, mock)

            # Create request
            req = proxy.running?('mod_111')
            sent = ::Orchestrator::Remote::Request.new(
                :running,
                'mod_111',
                nil,
                nil,
                nil,
                1
            )
            expect(@log[0]).to eq(sent)

            # Process request
            proxy.process(@log[0])
            @reactor.next_tick do
                expect(@log[1].id).to eq(1)
                expect(@log[1].type).to eq(:resolve)
                expect(@log[1].value).to eq(true)

                # Process response
                proxy.process(@log[1])
                req.then do |resp|
                    failed = resp != true
                end
            end
        end

        expect(failed).to be(false)
    end

    it "should perform remote debugging" do
        @reactor.run do
            mock = MockCtrl.new(@log)
            proxy = ::Orchestrator::Remote::Proxy.new(mock, mock, mock)

            # Create request
            callback = proc { |*args|
                @log << args
            }
            req = proxy.debug(:mod_111, callback)
            sent = ::Orchestrator::Remote::Request.new(
                :debug,
                :mod_111,
                nil,
                nil,
                nil,
                nil
            )
            expect(@log[0]).to eq(sent)

            # Process request
            proxy.process(@log[0])
            expect(@log[1]).to be(:registered)
            
            # Check log debugging is forwarded
            mock.log('test-logging')
            sent = ::Orchestrator::Remote::Request.new(
                :notify,
                'mod_111',
                :info,
                ['MockCtrl', 'test-logging'],
                nil,
                nil
            )
            expect(@log[2]).to eq(sent)

            # Ensure the debug callback is invoked
            proxy.process(@log[2])
            expect(@log[3]).to eq(['MockCtrl', 'mod_111', :info, 'test-logging'])

            # Ingore debugging data
            proxy.ignore(:mod_111, callback)
            sent = ::Orchestrator::Remote::Request.new(
                :ignore,
                :mod_111,
                nil,
                nil,
                nil,
                nil
            )
            expect(@log[4]).to eq(sent)
        end
    end

    it "should update module settings remotely" do
        @reactor.run do
            mock = MockCtrl.new(@log)
            proxy = ::Orchestrator::Remote::Proxy.new(mock, mock, mock)

            # Create request
            mod = ::Orchestrator::Module.new
            mod.ip = "10.10.10.10"
            proxy.update_settings('mod_111', mod)
            sent = ::Orchestrator::Remote::Request.new(
                :settings,
                'mod_111',
                mod,
                nil,
                nil,
                nil
            )
            expect(@log[0]).to eq(sent)

            # Process request
            proxy.process(@log[0])
            @reactor.next_tick do
                expect(@log[1]).to eq(mod)
            end
        end
    end

    it "should send an unload module request" do
        failed = true
        @reactor.run do
            mock = MockCtrl.new(@log)
            proxy = ::Orchestrator::Remote::Proxy.new(mock, mock, mock)

            # Create request
            req = proxy.unload('mod_111')
            sent = ::Orchestrator::Remote::Request.new(
                :push,
                'mod_111',
                :unload,
                nil,
                nil,
                1
            )
            expect(@log[0]).to eq(sent)

            # Process request
            proxy.process(@log[0])
            @reactor.next_tick do
                expect(@log[1]).to eq([:unload, 'mod_111', false])

                expect(@log[2].id).to eq(1)
                expect(@log[2].type).to eq(:resolve)
                expect(@log[2].value).to eq(true)

                # Process response
                proxy.process(@log[2])
                req.then do |resp|
                    failed = resp != true
                end
            end
        end

        expect(failed).to be(false)
    end

    it "should send a reload module request - failure response" do
        failed = true
        @reactor.run do
            mock = MockCtrl.new(@log)
            proxy = ::Orchestrator::Remote::Proxy.new(mock, mock, mock)

            # Create request
            req = proxy.reload('dep_111')
            sent = ::Orchestrator::Remote::Request.new(
                :push,
                'dep_111',
                :reload,
                nil,
                nil,
                1
            )
            expect(@log[0]).to eq(sent)

            # Process request
            proxy.process(@log[0])
            @reactor.next_tick do
                expect(@log[1].id).to eq(1)
                expect(@log[1].type).to eq(:reject)
                expect(@log[1].value).to eq('dependency dep_111 not found')

                # Process response
                proxy.process(@log[1])
                req.catch do |error|
                    failed = false
                end
            end
        end

        expect(failed).to be(false)
    end

    it "should send an expire cache request" do
        failed = true
        @reactor.run do
            begin
                mock = MockCtrl.new(@log)
                proxy = ::Orchestrator::Remote::Proxy.new(mock, mock, mock)

                zone = ::Orchestrator::Zone.new
                zone.name = 'test zone'
                zone.save!

                cs = ::Orchestrator::ControlSystem.new
                cs.name = 'testing cache expiry...'
                cs.edge_id = ::Orchestrator::Remote::NodeId
                cs.zones << zone.id
                begin
                    cs.save!
                rescue => e
                    puts "#{cs.errors.inspect}"
                    raise e
                end

                # Create request
                req = proxy.expire_cache(cs.id)
                sent = ::Orchestrator::Remote::Request.new(
                    :expire,
                    cs.id,
                    false,
                    nil,
                    nil,
                    1
                )
                expect(@log[0]).to eq(sent)

                # Process request
                proxy.process(@log[0])
                expect(@log[1]).to eq([:expire_cache, cs.id, false])

                expect(@log[2].id).to eq(1)
                expect(@log[2].type).to eq(:resolve)
                expect(@log[2].value).to eq(true)

                # Process response
                proxy.process(@log[2])
                req.then do |resp|
                    failed = resp != true
                end
            ensure
                cs.destroy
                zone.destroy
            end
        end

        expect(failed).to be(false)
    end
end
