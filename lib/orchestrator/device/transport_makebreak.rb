# frozen_string_literal: true

module Orchestrator
    module Device
        class MakebreakConnection < ::UV::OutboundConnection
            def post_init(manager, processor, tls)
                @manager = manager
                @processor = processor
                @config = @processor.config
                @tls = tls

                @connected = false
                @disconnecting = false
                @last_retry = 0

                @activity = nil     # Activity timer
                @connecting = nil   # Connection timer
                @retries = 2        # Connection retries
                @write_queue = []
            end

            attr_reader :delaying

            def stats
                {
                    connected: @connected,
                    connecting: !!@connecting,
                    disconnecting: @disconnecting,
                    last_retry: @last_retry,
                    retries: @retries,
                    write_queue: @write_queue.length,
                    activity: !!@activity
                }
            end

            def transmit(cmd)
                return if @terminated

                if @connected && !@disconnecting
                    # This is the same as TCP
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

                    # Inception
                    process_write_queue unless @write_queue.empty?
                    promise = write(data)
                    reset_timeout
                    if cmd[:wait]
                        promise.catch do |err|
                            if @processor.queue.waiting == cmd
                                # Fail fast
                                @processor.thread.next_tick do
                                    @processor.__send__(:resp_failure, err)
                                end
                            else
                                cmd[:defer].reject(err)
                            end
                        end
                    end
                elsif @retries < 2
                    @write_queue << cmd
                    reconnect unless @disconnecting
                else
                    cmd[:defer].reject(Error::CommandFailure.new "transmit aborted as disconnected")
                end
                # discards data when officially disconnected
            end

            def on_connect(transport)
                @connected = true
                @disconnecting = false

                if @connecting
                    @connecting.cancel
                    @connecting = nil
                end

                @manager.logger.debug 'makebreak connection made'
                return terminate if @terminated

                if @tls
                    begin
                        use_tls(@config)
                    rescue => e
                        @manager.logger.print_error(e, 'error starting tls')
                    end
                end

                return init_connection unless @config[:wait_ready]

                # Don't wait forever
                @delay_timer = @manager.thread.scheduler.in(@processor.config[:wait_ready_timeout]) do
                    @manager.logger.warn 'timeout waiting for device to be ready'
                    close_connection
                    @manager.notify_disconnected
                end
                @delaying = String.new
            end

            def on_close
                @delaying = nil
                @connected = false
                @disconnecting = false


                if @connecting
                    @connecting.cancel
                    @connecting = nil
                end

                @manager.logger.debug 'makebreak disconnected'

                # Prevent re-connect if terminated
                return if @terminated


                @retries += 1
                the_time = @processor.thread.now
                boundry = @last_retry + @config[:thrashing_threshold]

                # ensure we are not thrashing (rapid connect then disconnect)
                # This equals a disconnect and requires a warning
                if @retries == 1 && boundry >= the_time
                    @retries += 1
                    @manager.logger.warn('possible connection thrashing. Disconnecting')
                end

                @activity.cancel if @activity
                @activity = nil

                if @retries == 1
                    if @write_queue.length > 0
                        # We reconnect here as there are pending writes
                        @last_retry = the_time
                        reconnect
                    else
                        @processor.thread.next_tick { @processor.soft_disconnect }
                    end
                else # retries > 1
                    @write_queue.clear

                    variation = 1 + rand(2000)
                    @connecting = @manager.thread.scheduler.in(3000 + variation) do
                        @connecting = nil
                        reconnect
                    end

                    # we mark the queue as offline if more than 1 reconnect fails
                    #  or if the first connect fails
                    if @retries == 2 || (@retries == 3 && @last_retry == 0)
                        @processor.disconnected
                        @processor.queue.offline(@config[:clear_queue_on_disconnect])
                    else
                        @processor.thread.next_tick { @processor.soft_disconnect }
                    end
                end
            end

            def on_read(data, *args)
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

                    init_connection(true)
                    @processor.buffer(rem) unless rem.empty?
                end
            end

            def terminate
                @terminated = true
                @connecting.cancel if @connecting
                @activity.cancel if @activity
                @delay_timer.cancel if @delay_timer
            ensure
                @connecting = @activity = @delay_timer = nil
                close_connection(:after_writing) if @connected
            end

            def disconnect
                return unless @connected && !@disconnecting

                if @delay_timer
                    @delay_timer.cancel
                    @delay_timer = nil
                end

                if @connecting
                    @disconnecting = false
                else
                    @disconnecting = true
                    close_connection(:after_writing)
                end
            end


            protected


            def reset_timeout
                return if @terminated

                if @activity
                    @activity.cancel
                    @activity = nil
                end

                timeout = @config[:inactivity_timeout] || 0
                if timeout > 0
                    @activity = @manager.thread.scheduler.in(timeout) do
                        @activity = nil
                        disconnect
                    end
                else # Wait for until queue complete
                    waiting = @processor.queue.waiting
                    if waiting
                        if waiting[:makebreak_set].nil?
                            waiting[:defer].promise.finally { reset_timeout }
                            waiting[:makebreak_set] = true
                        end
                    elsif @processor.queue.length == 0
                        disconnect
                    end
                end
            end

            def reconnect
                return if @connected || @disconnecting || @connecting
                super
            end

            def init_connection(wait_ready = false)
                if wait_ready
                    # Process the input buffer before transmit, primarily
                    # in case the data is relevant to the before_transmit
                    # callback.
                    @processor.thread.next_tick { process_write_queue }
                else
                    process_write_queue
                end

                # Notify module
                @processor.queue.online unless @processor.queue.online?
                @processor.connected unless @processor.connected?
                @retries = 0

                # Start inactivity timeout
                reset_timeout
            end

            def process_write_queue
                # Write pending directly
                queue = @write_queue
                @write_queue = []
                while queue.length > 0
                    transmit(queue.shift)
                end
            end
        end
    end
end
