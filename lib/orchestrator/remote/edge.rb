# encoding: ASCII-8BIT
# frozen_string_literal: true

require 'set'

module Orchestrator
    module Remote
        class Edge < ::UV::OutboundConnection
            def post_init(this_node, remote_node)
                @node = this_node
                @remote_node = remote_node

                # Delay retry by default if connection fails on load
                @retries = 1        # Connection retries
                @connecting = nil   # Connection timer

                # Last retry shouldn't break any thresholds
                @last_retry = 0
                @terminated = false
                @validated = false

                @ctrl = ::Orchestrator::Control.instance
                @dep_man = ::Orchestrator::DependencyManager.instance
                @tokenise = ::UV::AbstractTokenizer.new(ParserSettings)
                @logger = ::SpiderGazelle::Logger.instance
            end

            def on_connect(transport)
                if @terminated
                    close_connection
                    return
                end

                use_tls
                @validated = false

                # Enable keep alive every 30 seconds
                keepalive(30)
                @retries = 0
                @logger.info "Connection made to node #{@remote_node}"

                # Authenticate with the remote server
                output = "hello 1.0 #{@node}"
                write("#{[output.length].pack('V')}#{output}")
                @proxy = Proxy.new(@ctrl, @dep_man, transport)
            end

            attr_reader :proxy

            def on_close
                return if @terminated

                @retries += 1
                the_time = @reactor.now

                # 1.5 seconds is the minimum time between successful connections
                # Faster than this and there is probably something seriously wrong
                boundry = @last_retry + 1500

                if @retries == 1 && boundry >= the_time
                    @retries += 1
                end

                if @retries == 1
                    @last_retry = the_time
                    reconnect
                else
                    variation = 1 + rand(2000)
                    @connecting = @ctrl.reactor.scheduler.in(2000 + variation) do
                        @connecting = nil
                        reconnect
                    end
                end
            end

            def on_read(data, *_)
                @tokenise.extract(data).each do |msg|
                    msg = msg[4..-1]

                    if msg[0] == 'p'
                            # pong
                            write(PING)
                    elsif @validated
                        begin
                            @proxy.process Marshal.load(msg)
                        rescue => e
                            close_connection
                            @logger.warn "Connection to node #{@remote_node} was closed due to bad data"
                        end
                    elsif msg[0] == 'h'
                        # Message is: 'hello password'
                        # This very basic auth gives us some confidence that the remote is who they claim to be
                        _, version, node = msg.split(' ')
                        if version[0] == '1' && node == @remote_node
                            @validated = true
                        else
                            close_connection
                            @logger.warn "Connection to node #{@remote_node} was closed due to mismatch: #{msg}"
                        end
                    end
                end
            end

            def terminate
                @terminated = true
                close_connection(:after_writing)
            end
        end
    end
end
