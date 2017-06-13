# frozen_string_literal: true

# NOTE:: include RSpec::Matchers

module Orchestrator
    module Testing
        class MockConnection
            def transmit(cmd)
                data = cmd[:data]

                if @config[:before_transmit]
                    begin
                        data = @config[:before_transmit].call(data, cmd)
                    rescue => err
                        @manager.logger.print_error(err, 'error in before_transmit callback')

                        if @processor.queue.waiting == cmd
                            # Fail fast
                            @processor.thread.next_tick do
                                @processor.__send__(:resp_failure, err)
                            end
                        else
                            cmd[:defer].reject(err)
                        end

                        # Don't try and send anything
                        return
                    end
                end

                @outgoing << cmd[:data]
                puts "TX: #{cmd[:data].inspect}"
            end

            def receive(data)
                if @config[:before_buffering]
                    begin
                        data = @config[:before_buffering].call(data)
                    rescue => err
                        # We'll continue buffering and provide feedback as to the error
                        @manager.logger.print_error(err, 'error in before_buffering callback')
                    end
                end

                if @delaying
                    @delaying << data
                    result = @delaying.split(@config[:wait_ready], 2)
                    if result.length > 1
                        @delaying = false
                        @delay_timer.cancel
                        @delay_timer = nil
                        rem = result[-1]
                        @processor.buffer(rem) unless rem.empty?
                    end
                else
                    @processor.buffer(data)
                end
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

                if @config[:wait_ready]
                    # Don't wait forever
                    @delay_timer = @manager.thread.scheduler.in(@processor.defaults[:timeout]) do
                        @manager.logger.warn 'timeout waiting for device to be ready'
                        @manager.notify_disconnected
                    end
                    @delaying = String.new
                end
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
                @thread.next_tick do
                    @processor.connected
                end
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
