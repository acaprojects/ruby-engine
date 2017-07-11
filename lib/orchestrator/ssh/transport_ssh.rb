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
                
                reconnect
            end

            def reconnect
                return if @terminated

                connecting = ::ESSH.p_start(@settings.ip, @manager.username, **@manager.ssh_settings)
                connecting.then { |connection|
                    @connection = connection
                    @last_keepalive_sent_at = Time.now.to_i

                    on_connect(connection.transport)
                }.catch { |error|
                    @connection = nil
                    @manager.logger.print_error(error, 'initializing SSH transport')

                    # reconnect after a cool down period as will probably continue to fail
                    # this usually represents an issue with authentication
                    variation = 1 + rand(2000)
                    @connecting = @scheduler.in(5000 + variation) do
                        @connecting = nil
                        reconnect
                    end
                }
            end

            def on_connect(transport)
                return transport.shutdown! if @terminated

                @processor.connected
                
                # Keep the socket open
                variation = 1 + rand(2000)
                @keep_alive&.cancel
                @keep_alive = @scheduler.every(30000 + variation) do
                    now = Time.now.to_i
                    last = @last_keepalive_sent_at + 15

                    if now > last
                        @manager.logger.debug 'requesting keepalive.'
                        @connection.send_global_request('keepalive@openssh.com') { |success, response|
                            @manager.logger.debug 'keepalive response successful.'
                        }
                    end
                end

                # Listen for socket close events
                transport.socket.finally do
                    on_close
                end
            end

            def on_close
                @connection = nil
                return if @terminated

                @processor.disconnected

                # Just for peace of mind
                @connecting&.cancel
                @connecting = nil

                @keep_alive&.cancel
                @keep_alive = nil

                reconnect
            end

            def terminate
                @terminated = true

                @connecting&.cancel
                @connecting = nil

                @keep_alive&.cancel
                @keep_alive = nil

                disconnect
            end

            def delaying; false; end

            def disconnect
                return unless @connection
                conn = @connection

                # We want to force disconnect after a short period of time
                @scheduler.in(1500) do
                    if conn&.transport&.socket && !conn.transport.socket.closed?
                        conn.transport.shutdown!
                    end
                end

                @manager.thread.next_tick do
                    # NOTE:: performed next tick as this blocks (coroutine)
                    conn.close
                end
            end

            def transmit(cmd)
                return if @terminated

                if @connection.nil?
                    cmd[:defer].reject(:disconnected)
                    return
                end

                data = cmd[:data]
                stream = cmd[:stream]

                @last_keepalive_sent_at = Time.now.to_i

                if stream && stream.respond_to?(:call)
                    begin
                        status = {}
                        channel = @connection.exec(data, status: status, &stream)
                        channel.promise.then { cmd[:resp].resolve(status) }.catch { |e| cmd[:resp].reject(e) }
                    rescue => e
                        @manager.logger.print_error(e, 'SSH command failure')
                        cmd[:resp].reject(e)
                    end
                else
                    promise = @connection.p_exec!(data)
                    cmd[:defer].resolve(promise)

                    if @processor.queue.waiting == cmd
                        promise.then { |result|
                            @processor.__send__(:resp_success, result)
                            result
                        }.catch { |e|
                            @processor.__send__(:resp_success, :abort)
                            @manager.logger.print_error(e, 'SSH command failure')
                            @manager.thread.reject(e) # continue the promise rejection
                        }
                    end
                end

                nil
            end
        end
    end
end
