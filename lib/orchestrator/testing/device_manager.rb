# frozen_string_literal: true

# NOTE:: include RSpec::Matchers

module Orchestrator
    module Testing
        class MockConnection
            def transmit(cmd)
                # Differenciate between service modules and device modules
                if cmd[:method] && cmd[:path]
                    @outgoing << cmd
                else
                    @outgoing << cmd[:data]
                end
            end

            def receive(data)
                @processor.buffer(data)
            end

            def check_outgoing(contains)
                index = @outgoing.index(contains)
                if index
                    @outgoing = @outgoing[(index + 1)..-1]
                    true
                else
                    false
                end
            end


            # ===============
            # used in devices
            # ===============
            def initialize(manager, processor, _ = nil)
                @incomming = []
                @outgoing = []

                @manager = manager
                @processor = processor
                @config = @processor.config
            end

            attr_reader :delaying, :outgoing, :incomming

            def disconnect
                @processor.disconnected
                @incomming = []
                @outgoing = []
                @processor.connected
            end

            def terminate; end

            def force_offline
                @processor.disconnected
                @processor.queue.offline(@config[:clear_queue_on_disconnect])
                @incomming = []
                @outgoing = []
            end

            def force_online
                @processor.queue.online
                @processor.connected
            end


            # ================
            # used in services
            # ================
            def server
                self
            end

            def cookiejar
                self
            end

            def clear_cookies
                true
            end

            def middleware
                []
            end
        end

        class DeviceManager < ::Orchestrator::Core::ModuleManager
            attr_reader :processor, :connection


            # Ensure remote isn't ever called
            def trak(name, value, remote = false)
                super(name, value, false)
            end


            def start_local(online = true)
                return false if not online
                return true if @processor

                @processor = ::Orchestrator::Device::Processor.new(self)
                super online

                @logger.level = :debug
                @connection = MockConnection.new(self, @processor)

                @processor.transport = @connection
                @processor.connected
                true # for REST API
            end

            def stop_local
                super
                @processor.terminate if @processor
                @processor = nil
                @connection.terminate if @connection
                @connection = nil
            end

            def apply_config
                cfg = @klass.__default_config(@instance) if @klass.respond_to? :__default_config
                opts = @klass.__default_opts(@instance)  if @klass.respond_to? :__default_opts

                if @processor
                    @processor.config = cfg
                    @processor.send_options(opts)
                end
            rescue => e
                @logger.print_error(e, 'error applying config, driver may not function correctly')
            end

            def notify_connected
                if @instance.respond_to? :connected, true
                    begin
                        @instance.__send__(:connected)
                    rescue => e
                        @logger.print_error(e, 'error in module connected callback')
                    end
                end
            end

            def notify_disconnected
                if @instance.respond_to? :disconnected, true
                    begin
                        @instance.__send__(:disconnected)
                    rescue => e
                        @logger.print_error(e, 'error in module disconnected callback')
                    end
                end
            end

            def notify_received(data, resolve, command = nil)
                begin
                    blk = command.nil? ? nil : command[:on_receive]
                    if blk.respond_to? :call
                        blk.call(data, resolve, command)
                    elsif @instance.respond_to? :received, true
                        @instance.__send__(:received, data, resolve, command)
                    else
                        @logger.warn('no received function provided')
                        :abort
                    end
                rescue => e
                    @logger.print_error(e, 'error in received callback')
                    return :abort
                end
            end
        end
    end
end
