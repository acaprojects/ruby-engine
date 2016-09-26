# frozen_string_literal: true

require 'uv-rays'
require 'json'
require 'set'

module Orchestrator
    module Remote
        SERVER_PORT = 17400

        Connection = Struct.new(:tokeniser, :edge, :parser, :node_id, :timeout, :io, :poll) do
            def validated?
                !!self.node_id
            end
        end

        ParserSettings = {
            indicator: "\x02",
            delimiter: "\x03"
        }

        class Master

            def initialize
                @thread = ::Libuv::Reactor.default
                @logger = ::SpiderGazelle::Logger.instance
                @ctrl = ::Orchestrator::Control.instance
                @dep_man = ::Orchestrator::DependencyManager.instance
                @boot_time = Time.now.to_i

                @connections = {}
                @connected_to = Set.new

                @tokenise = method(:tokenise)
                @node = @ctrl.nodes[NodeId]

                init_node_states
                start_server
            end


            attr_reader :thread

            
            protected


            def start_server
                # Bind the socket
                @tcp = @thread.tcp
                        .bind('0.0.0.0', SERVER_PORT, method(:new_connection))
                        .listen(64) # smallish backlog is all we need

                # Delegate errors
                @tcp.catch @bind_error

                @logger.info "Node server on tcp://0.0.0.0:#{SERVER_PORT}"
            end

            def new_connection(client)
                # Build the connection object
                connection = Connection.new
                @connections[client.object_id] = connection

                connection.timeout = @thread.scheduler.in(15000) do
                    # Shutdown connection if validation doesn't occur within 15 seconds
                    client.close
                end
                connection.tokeniser = ::UV::BufferedTokenizer.new(ParserSettings)
                connection.io = client


                connection.poll = @thread.scheduler.every(60000) do
                    client.write "\x02ping\x03"
                end


                # Hook up the connection callbacks
                client.enable_nodelay
                client.catch do |error|
                    @logger.print_error(error, "Node connection error")
                end

                client.finally do
                    @connections.delete client.object_id
                    connection.poll.cancel

                    if connection.validated?
                        edge = @ctrl.nodes[connection.node_id]

                        # We may not have noticed the disconnect
                        if edge.proxy == connection.parser
                            edge.slave_disconnected
                            @connected_to.delete connection.node_id
                        end
                    else
                        connection.timeout.cancel
                    end
                end

                client.progress @tokenise

                # This is an encrypted connection
                client.start_tls(server: true)
                client.start_read
            end

            def tokenise(data, client)
                connection = @connections[client.object_id]
                connection.tokeniser.extract(data).each do |msg|
                    process connection, msg
                end
            end


            DECODE_OPTIONS = {
                symbolize_names: true
            }.freeze

            def process(connection, msg)
                # Connection Maintenance
                return if msg[0] == 'p'

                if connection.validated?
                    begin
                        connection.parser.process ::JSON.parse(msg, DECODE_OPTIONS)
                    rescue => e
                        # TODO:: Log the error here
                    end
                else
                    begin
                        # Will send an auth message: node_id password
                        node_str, start_times, pass = msg.split(' ')
                        node_id = node_str.to_sym
                        start_time = start_times.to_i
                        edge = @ctrl.nodes[node_id]

                        if edge.password == pass
                            connection.timeout.cancel
                            connection.timeout = nil
                            connection.node_id = node_id
                            connection.parser = Proxy.new(@ctrl, @dep_man, connection.io)
                            connection.edge = edge

                            # Provide the edge node with our failover data
                            if edge.is_failover_host && edge.host_active?
                                connection.io.write "\x02hello #{@node.password} #{edge.failover_time}\x03"
                            else
                                connection.io.write "\x02hello #{@node.password}\x03"
                            end
                            @connected_to << node_id
                            edge.slave_connected connection.parser, start_time
                        else
                            ip, _ = connection.io.peername
                            connection.io.close
                            @logger.warn "Connection from #{ip} was closed due to bad credentials: #{edge.password} !== #{pass}"
                        end
                    rescue => e
                        ip, _ = connection.io.peername
                        connection.io.close
                        @logger.warn "Connection from #{ip} was closed due to bad data"
                    end
                end
            end


            def init_node_states
                # If we are the undisputed master then we want to start our modules straight away
                # These modules would have no failover node
                @node.start_modules if @node.is_only_master?

                @ctrl.nodes.each_pair do |id, node|
                    node.slave_disconnected if id != NodeId
                end
            end

            def node_added(node_id)
                # TODO:: init this nodes state
            end
        end
    end
end
