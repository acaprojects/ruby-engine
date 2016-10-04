# frozen_string_literal: true

module Orchestrator
    module Service
        class TransportHttp
            def initialize(manager, processor)
                @manager = manager
                @settings = @manager.settings
                @processor = processor

                # Load http endpoint after module has had a chance to update the config
                config = @processor.config
                config[:tls] ||= @settings.tls
                config[:tokenize] = false
                @server = UV::HttpEndpoint.new @settings.uri, config

                @state = :connected

                @manager.thread.next_tick do
                    # Call connected (we only need to do this once)
                    # We may never be connected, this is just to signal that we are ready
                    @processor.connected
                end
            end

            
            attr_reader :server


            def delaying; false; end

            def transmit(cmd)
                return if @terminated

                # TODO:: Support multiple simultaneous requests (multiple servers)

                # Log the requests
                @manager.logger.debug {
                    "requesting #{cmd[:method]}: #{@settings.uri}#{cmd[:path]}"
                }

                @server.request(cmd[:method], cmd).then(
                    proc { |result|
                        if @state != :connected
                            @state = :connected
                            @manager.notify_connected
                            if @processor.config[:update_status]
                                @manager.trak(:connected, true)
                            end
                        end
                        
                        # Make sure the request information is always available
                        result[:request] = cmd
                        result[:body] = result.body  # here for module compatibility
                        @processor.buffer(result)

                        @manager.logger.debug {
                            msg = String.new("success #{cmd[:method]}: #{@settings.uri}#{cmd[:path]}\n")
                            msg << "result: #{result}"
                            msg
                        }

                        nil
                    },
                    proc { |failure|
                        if failure == :connection_failure && @state != :disconnected
                            @state = :disconnected
                            @manager.notify_disconnected
                            if @processor.config[:update_status]
                                @manager.trak(:connected, false)
                            end
                        end

                        # Fail fast (no point waiting for the timeout)
                        if @processor.queue.waiting #== cmd
                            @processor.__send__(:resp_failure, :failed)
                        end

                        @manager.logger.debug {
                            msg = String.new("failed #{cmd[:method]}: #{@settings.uri}#{cmd[:path]}\n")
                            msg << "req headers: #{cmd[:headers]}\n"
                            msg << "req body: #{cmd[:body]}\n"
                            msg << "result: #{failure}"
                            msg
                        }
                        
                        nil
                    }
                )

                nil
            end

            def terminate
                @terminated = true
                @server.cancel_all
            end
        end
    end
end
