# frozen_string_literal: true

require 'ipaddr'

module Orchestrator
    module Device
        class Manager < ::Orchestrator::Core::ModuleManager
            MulticastRangeV4 = IPAddr.new('224.0.0.0/4')
            MulticastRangeV6 = IPAddr.new('ff00::/8')

            attr_reader :processor, :connection

            # Direct access required for child classes
            alias :core_start_local :start_local

            def start_local(online = @settings.running)
                return false if not online
                return true if @processor
                @processor = Processor.new(self)

                super online # Calls on load (allows setting of tls certs)

                # Load UV-Rays abstraction here
                @connection = if @settings.udp
                    begin
                        if MulticastRangeV4 === @settings.ip
                            bind_ip = '0.0.0.0'
                            ::UV.open_datagram_socket(::Orchestrator::Device::MulticastConnection, bind_ip, @settings.port, self, @processor, bind_ip)
                        elsif MulticastRangeV6 === @settings.ip
                            bind_ip = '::'
                            ::UV.open_datagram_socket(::Orchestrator::Device::MulticastConnection, bind_ip, @settings.port, self, @processor, bind_ip)
                        else
                            UdpConnection.new(self, @processor)
                        end
                    rescue IPAddr::InvalidAddressError
                        UdpConnection.new(self, @processor)
                    end
                elsif @settings.makebreak
                    ::UV.connect(@settings.ip, @settings.port, MakebreakConnection, self, @processor, @settings.tls)
                else
                    ::UV.connect(@settings.ip, @settings.port, TcpConnection, self, @processor, @settings.tls)
                end

                @processor.transport = @connection
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

                @thread.next_tick { update_connected_status(true) }
            end

            def notify_disconnected
                if @instance.respond_to? :disconnected, true
                    begin
                        @instance.__send__(:disconnected)
                    rescue => e
                        @logger.print_error(e, 'error in module disconnected callback')
                    end
                end

                @thread.next_tick { update_connected_status(false) }
            end

            def notify_hostname_resolution(ip)
                if @instance.respond_to? :hostname_resolution, true
                    begin
                        @instance.__send__(:hostname_resolution, ip)
                    rescue => e
                        @logger.print_error(e, 'error in module hostname resolution callback')
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
