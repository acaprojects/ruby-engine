# frozen_string_literal: true

require 'ipaddress'
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

                @retries = 0        # Connection retries
                @connecting = nil   # Connection timer
                
                reconnect
            end

            attr_reader :connection

            def reconnect
                return if @terminated

                # Perform DNS lookup in reactor
                ip_address = @settings.ip
                if not IPAddress.valid? ip_address
                    begin
                        ip_address = @manager.thread.lookup(ip_address)[0][0]
                        raise 'DNS successful however no IP address was found' if ip_address.nil?
                    rescue => error
                        connection_error(error)
                        return
                    end
                end

                @manager.notify_hostname_resolution(ip_address)

                # Connect using reactor aware version of ruby NET SSH
                connecting = ::ESSH.p_start(ip_address, @manager.username, **@manager.ssh_settings)
                connecting.then { |connection|
                    @connection = connection
                    @last_keepalive_sent_at = Time.now.to_i

                    # Listen for socket close events
                    connection.transport.socket.finally do
                        on_close
                    end

                    @connecting = @manager.thread.scheduler.in(10000) do
                        @manager.logger.error('failed to initialize SSH shell after 10 seconds')
                        connection.transport.shutdown!
                    end

                    connection.open_channel do |ch|
                        ch.request_pty(modes: { Net::SSH::Connection::Term::ECHO => 0 }) do |ch, success|
                            open_shell(ch, success)
                        end
                    end
                }.catch { |error| connection_error(error) }
            end

            def open_shell(ch, success)
                if success
                    ch.send_channel_request('shell') do |ch, success|
                        if success
                            @shell = ch
                            ch.on_data { |channel, data| on_read(channel, data) }
                            ch.on_extended_data { |channel, data| on_read(channel, data) }
                            on_connect(connection.transport)
                        else
                            @manager.logger.warn('failed to open SSH shell')
                            transport.shutdown!
                        end
                    end
                else
                    @manager.logger.warn('failed to open SSH shell')
                    transport.shutdown!
                end
            end

            def on_connect(transport)
                return transport.shutdown! if @terminated
                return init_connection unless @config[:wait_ready]

                @delay_timer = @manager.thread.scheduler.in(@config[:wait_ready_timeout]) do
                    @manager.logger.warn 'timeout waiting for device to be ready'
                    transport.shutdown!
                end
                @delaying = String.new
            end

            def on_read(channel, data)
                if @config[:before_buffering]
                    begin
                        data = @config[:before_buffering].call(data)
                    rescue => err
                        # We'll continue buffering and provide feedback as to the error
                        @manager.logger.print_error(err, 'error in before_buffering callback')
                    end
                end

                return @processor.buffer(data) unless @delaying

                @delaying << data
                result = @delaying.split(@config[:wait_ready], 2)
                if result.length > 1
                    @delaying = nil
                    @delay_timer.cancel
                    @delay_timer = nil
                    rem = result[-1]

                    init_connection # This clears the buffer
                    @processor.buffer(rem) unless rem.empty?
                end
            end

            def on_close
                @shell = nil
                @delaying = nil
                @connection = nil
                return if @terminated

                @processor.disconnected if @retries == 0
                @processor.queue.offline(@config[:clear_queue_on_disconnect]) if @retries == 2
                @retries += 1

                @connecting&.cancel
                @connecting = nil

                @delay_timer&.cancel
                @delay_timer = nil

                @keep_alive&.cancel
                @keep_alive = nil

                reconnect
            end

            def terminate
                @terminated = true

                @connecting&.cancel
                @connecting = nil

                @delay_timer&.cancel
                @delay_timer = nil

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

                if cmd[:exec]
                    if @connection.nil? || @retries > 0
                        cmd[:exec].reject(:disconnected)
                        return
                    end

                    data = cmd[:data]
                    stream = cmd[:stream]

                    if stream && stream.respond_to?(:call)
                        begin
                            status = {}
                            channel = @connection.exec(data, status: status, &stream)
                            channel.promise.then { cmd[:exec].resolve(status) }.catch { |e| cmd[:exec].reject(e) }
                        rescue => e
                            @manager.logger.print_error(e, 'SSH command failure')
                            cmd[:exec].reject(e)
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

                    @last_keepalive_sent_at = Time.now.to_i
                elsif @shell.nil?
                    cmd[:defer].reject(:disconnected)
                else
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

                    @last_keepalive_sent_at = Time.now.to_i
                    @shell.send_data(data)
                end

                nil
            end


            protected


            def connection_error(error)
                @connection = nil
                @manager.logger.print_error(error, 'initializing SSH transport')

                return if @terminated

                # reconnect after a cool down period as will probably continue to fail
                # this usually represents an issue with authentication
                variation = 1 + rand(2000)
                @connecting = @scheduler.in(5000 + variation) do
                    @connecting = nil
                    reconnect
                end
            end

            def init_connection
                @connecting&.cancel
                @connecting = nil

                if @terminated
                    disconnect
                    return
                end

                # We only have to mark a queue online if more than 1 retry was required
                @processor.queue.online if @retries > 1
                @retries = 0
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
            end
        end
    end
end
