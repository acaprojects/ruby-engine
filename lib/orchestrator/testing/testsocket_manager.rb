# frozen_string_literal: true

require 'set'
require 'json'

module Orchestrator
    module Testing
        class TestsocketManager
            def initialize(ws, spec_file)
                @ws = ws
                @reactor = ws.reactor
                @spec_file = spec_file

                @ws.progress method(:on_message)
                @ws.finally method(:on_shutdown)
                @ws.on_open method(:on_open)
            end


            protected


            def on_open(ws)
                # spawn process
                @process = @reactor.spawn('rake', args: "module:test[#{@spec_file}]")

                # hook-up input and output to WS
                @process.stdout.progress do |data|
                    begin
                        @ws.text(data.encode('UTF-8', :invalid => :replace, :undef => :replace))
                    rescue => e
                        @ws.text("\n#{e.message}\n#{e.backtrace.join("\n")}")
                    end
                end

                @process.stderr.progress do |data|
                    begin
                        @ws.text(data.encode('UTF-8', :invalid => :replace, :undef => :replace))
                    rescue => e
                        @ws.text("\n#{e.message}\n#{e.backtrace.join("\n")}")
                    end
                end

                @process.finally do
                    @ws.close
                end

                @process.stdout.start_read
                @process.stderr.start_read
            end

            def on_message(data, ws)
                @process.stdin.write(data)
            end

            def on_shutdown
                @process.kill
            end
        end
    end
end
