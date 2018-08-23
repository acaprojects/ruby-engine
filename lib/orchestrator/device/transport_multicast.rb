
module Orchestrator
    module Device
        class MulticastConnection < ::UV::DatagramConnection
            def post_init(manager, processor, bind_ip)
                @processor = processor
                @manager = manager
                @thread = manager.thread
                @config = @processor.config

                @processor.queue.online

                settings = manager.settings
                @ip = settings.ip
                @port = settings.port

                # Join the multicast group
                @reactor.next_tick do
                    @transport.join(@manager.settings.ip, bind_ip)
                    disable_multicast_loop
                    @processor.connected
                end
            end

            def enable_multicast_loop
                @transport.enable_multicast_loop
            end

            def disable_multicast_loop
                @transport.disable_multicast_loop
            end


            attr_reader :delaying


            def transmit(cmd)
                return if @terminated

                # This is the same as MakeBreak
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

                promise = send_datagram(data, @ip, @port)

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
            end

            def on_read(data, ip, port, transport)
                if @config[:before_buffering]
                    begin
                        data = @config[:before_buffering].call(data)
                    rescue => err
                        # We'll continue buffering and provide feedback as to the error
                        @manager.logger.print_error(err, 'error in before_buffering callback')
                    end
                end

                @processor.buffer(data)
            end

            def disconnect(__user_initiated = nil); end

            def terminate
                @terminated = true
                @delay_timer.cancel if @delay_timer
                close_connection
            end
        end
    end
end
