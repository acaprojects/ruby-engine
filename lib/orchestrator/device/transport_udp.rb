# frozen_string_literal: true

module Orchestrator
    module Device
        class UdpConnection
            def initialize(manager, processor)
                @manager = manager
                @reactor = manager.thread
                @processor = processor
                @config = @processor.config

                settings = manager.settings
                @ip = settings.ip
                @port = settings.port
                @on_read = method(:on_read)

                # One per loop unless port specified
                @udp_server = @reactor.udp_service

                if IPAddress.valid? @ip
                    @attached_ip = @ip
                    @udp_server.attach(@attached_ip, @port, @on_read)
                    @reactor.next_tick do
                        # Call connected (we only need to do this once)
                        @processor.connected
                    end
                else
                    variation = 1 + rand(60000 * 5)  # 5min
                    @checker = @manager.get_scheduler.in(60000 * 5 + variation) do
                        find_ip(@ip)
                    end
                    find_ip(@ip)
                end
            end

            def delaying; false; end

            def transmit(cmd)
                return if @terminated
                @udp_server.send(@attached_ip, @port, cmd[:data])
            end

            def on_read(data)
                # We schedule as UDP server may be on a different thread
                @reactor.schedule do
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
            end

            def terminate
                #@processor.disconnected   # Disconnect should never be called
                @terminated = true
                if @searching
                    @searching.cancel
                    @searching = nil
                else
                    @udp_server.detach(@attached_ip, @port)
                end

                @checker.cancel if @checker
            end

            def disconnect; end


            protected


            def find_ip(hostname)
                @reactor.lookup(hostname).then(proc{ |result|
                    update_ip(result[0][0])
                }, proc { |failure|
                    variation = 1 + rand(8000)
                    @searching = @manager.get_scheduler.in(8000 + variation) do
                        @searching = nil
                        find_ip(hostname)
                    end
                })
            end

            def update_ip(ip)
                if ip != @attached_ip
                    if @attached_ip
                        @udp_server.detach(@attached_ip, @port)
                    else
                        @processor.connected
                    end
                    @attached_ip = ip
                    @udp_server.attach(@attached_ip, @port, @on_read)
                end
            end
        end
    end
end
