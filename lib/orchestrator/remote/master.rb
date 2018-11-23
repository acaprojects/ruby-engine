# encoding: ASCII-8BIT
# frozen_string_literal: true

require 'uv-rays'
require 'json'
require 'set'

module Orchestrator
    module Remote
        Connection = Struct.new(:tokeniser, :parser, :node_id, :timeout, :io, :poll) do
            def validated?
                !!self.node_id
            end
        end

        ParserSettings = {
            callback: lambda do |byte_str|
                return false if byte_str.bytesize < 4
                length = byte_str[0...4].unpack('V')[0] + 4
                return length if byte_str.length >= length
                false
            end
        }

        PING = "#{[1].pack('V')}p"

        class Master

            def initialize(node_id)
                @thread = ::Libuv::Reactor.default
                @logger = ::SpiderGazelle::Logger.instance
                @ctrl = ::Orchestrator::Control.instance
                @dep_man = ::Orchestrator::DependencyManager.instance
                @boot_time = Time.now.to_i

                @connections = {}
                @connected_to = Set.new

                @node_id = node_id
                @bind, @port = THIS_NODE.split(':')
                @port = @port.to_i

                start_server
            end

            attr_reader :thread

            protected

            def start_server
                # Bind the socket
                @tcp = @thread.tcp
                        .bind(@bind, @port) { |client| new_connection(client) }
                        .listen(64) # smallish backlog is all we need

                @tcp.catch do |error|
                    @logger.print_error(error, "Remote binding error")
                end

                @logger.info "Node server on tcp://#{@node_id}"
            end

            def new_connection(client)
                # Build the connection object
                connection = Connection.new
                @connections[client.object_id] = connection

                connection.timeout = @thread.scheduler.in(15000) do
                    # Shutdown connection if validation doesn't occur within 15 seconds
                    client.close
                end
                connection.tokeniser = ::UV::AbstractTokenizer.new(ParserSettings)
                connection.io = client

                # Ping
                connection.poll = @thread.scheduler.every(20000) do
                    client.write PING
                end

                # Hook up the connection callbacks
                client.enable_nodelay
                client.catch do |error|
                    @logger.print_error(error, "Node connection error")
                end

                client.finally do
                    @connections.delete client.object_id
                    @connected_to.delete connection.node_id
                    connection.timeout.cancel if !connection.validated?
                    connection.poll.cancel
                end

                client.progress do |data, client|
                    connection = @connections[client.object_id]
                    connection.tokeniser.extract(data).each do |msg|
                        process connection, msg[4..-1]
                    end
                end

                # This is an encrypted connection
                client.start_tls(server: true)
                client.start_read
            end

            def process(connection, msg)
                # Connection Maintenance
                return if msg[4] == 'p'
                msg = msg[4..-1]

                if connection.validated?
                    begin
                        connection.parser.process Marshal.load(msg)
                    rescue => e
                        # TODO:: Log the error here
                    end
                else
                    begin
                        # Will send an auth message: hello version node_id
                        _, version, node = msg.split(' ')

                        if version[0] == '1'
                            connection.timeout.cancel
                            connection.timeout = nil
                            connection.node_id = node
                            connection.parser = Proxy.new(@ctrl, @dep_man, connection.io)

                            # Provide the edge node with our failover data
                            output = "hello 1.0 #{@node}"
                            connection.io.write("#{[output.length].pack('V')}#{output}")
                            @connected_to << node
                        else
                            ip, _ = connection.io.peername
                            connection.io.close
                            @logger.warn "Connection from #{ip} was closed due to bad credentials: #{msg}"
                        end
                    rescue => e
                        ip, _ = connection.io.peername
                        connection.io.close
                        @logger.warn "Connection from #{ip} was closed due to bad data"
                    end
                end
            end
        end
    end
end
