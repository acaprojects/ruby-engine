# frozen_string_literal: true

require 'set'


# This is used to grab the default edge node
require File.expand_path('../../../app/models/orchestrator/edge_control.rb', File.dirname(__FILE__))


module Orchestrator
    module Remote
        begin
            # export ENGINE_NODE_ID=edge_1-10

            NodeId = ENV['ENGINE_NODE_ID'].to_sym
        rescue => e
            puts "\nENGINE_NODE_ID env var not set\n"
            NodeId = :run_migrations_and_reboot
        end

        class Edge < ::UV::OutboundConnection
            def post_init(this_node, remote_node)
                @node = this_node
                @remote_node = remote_node
                @boot_time = Time.now.to_i

                # Delay retry by default if connection fails on load
                @retries = 1        # Connection retries
                @connecting = nil   # Connection timer

                # Last retry shouldn't break any thresholds
                @last_retry = 0
                @terminated = false
                @validated = false

                @ctrl = ::Orchestrator::Control.instance
                @dep_man = ::Orchestrator::DependencyManager.instance
                @tokenise = ::UV::BufferedTokenizer.new(ParserSettings)
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


                ip, _ = transport.peername
                @logger.info "Connection made to node #{@remote_node.id} (#{ip})"

                # Authenticate with the remote server
                write("#{NodeId} #{@boot_time} #{@node.password}\x00\x00\x00\x03")
                @proxy = Proxy.new(@ctrl, @dep_man, transport)
            end

            attr_reader :proxy

            def on_close
                return if @terminated

                @retries += 1
                the_time = @reactor.now

                @node.master_disconnected

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
                    if msg[0] == 'p'
                            # pong
                            write("p\x00\x00\x00\x03")
                    elsif msg[0] == 'h'
                        # Message is: 'hello password'
                        # This very basic auth gives us some confidence that the remote is who they claim to be
                        _, pass, time = msg.split(' ')
                        if @remote_node.password == pass
                            @validated = true
                            @node.master_connected(@proxy, @boot_time, time ? time.to_i : nil)
                        else
                            ip, _ = @transport.peername
                            close_connection
                            @logger.warn "Connection to node #{@remote_node.id} (#{ip}) was closed due to bad credentials"
                        end
                    else
                        begin
                            @proxy.process Marshal.load(msg)
                        rescue => e
                            ip, _ = @transport.peername
                            close_connection
                            @logger.warn "Connection to node #{@remote_node.id} (#{ip}) was closed due to bad data"
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
