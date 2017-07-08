# frozen_string_literal: true

require 'evented-ssh'

module Orchestrator
    module Ssh
        class TransportSsh
            def initialize(manager, processor)
                @manager = manager
                @processor = processor
                @config = @processor.config
                @settings = @manager.settings
                @scheduler = @manager.thread.scheduler

                @connecting = nil   # Connection timer

                # TODO:: need to check these on update
                @ssh_settings = @manager.setting(:ssh) || {}
                @ssh_settings.merge!({
                    port: @settings.port,
                    non_interactive: true,
                    logger: @manager.logger
                })
                
                reconnect
            end

            def reconnect
                connecting = ::ESSH.p_start(@settings.ip, ssh_settings[:username], **@ssh_settings)
                connecting.then { |connection|
                    @connection = connection
                    on_connect(connection.transport)
                }.catch { |error|
                    @manager.logger.print_error(error, 'initializing SSH transport')

                    # reconnect after a cool down period as will probably continue to fail
                    # this usually represents an issue with authentication
                    variation = 1 + rand(2000)
                    @connecting = @scheduler.in(5000 + variation) do
                        @connecting = nil
                        init_connection
                    end
                }
            end

            def on_connect(transport)
                return transport.shutdown! if @terminated

                @processor.connected

                # Listen for socket close events
                transport.socket.finally do
                    on_close
                end
            end

            def on_close
                return if @terminated

                @processor.disconnected
                @connection = nil

                # Just for peace of mind
                @connecting.cancel if @connecting
                @connecting = nil

                reconnect
            end

            def terminate
                @terminated = true

                @connecting.cancel if @connecting
                @connecting = nil

                if @connection
                    # TODO:: put a timeout here and force the socket closed after
                    # a few seconds if still connected (might be streaming)
                    @connection.close # NOTE:: this blocks (coroutine)
                    @connection = nil
                end
            end

            def delaying; false; end

            def transmit(cmd)
                return if @terminated || @connection.nil?

                data = cmd[:data]
                stream = cmd[:stream]

                if stream && stream.respond_to?(:call)

                else
                    cmd[:defer].resolve(@connection.p_exec!(data))
                end
            end
        end
    end
end
