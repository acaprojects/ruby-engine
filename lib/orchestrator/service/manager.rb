# frozen_string_literal: true

module Orchestrator
    module Service
        class Manager < ::Orchestrator::Device::Manager
            def initialize(*args)
                super(*args)

                # Do we want to start here?
                # Should be ok.
                @thread.next_tick method(:start) if @settings.running
            end

            def start_local(online = @settings.running)
                return false if not online
                return true if @processor

                @processor = Orchestrator::Device::Processor.new(self)
                core_start_local online # Calls on load (allows setting of tls certs)

                # After super so we can apply config like NTLM
                @connection = TransportHttp.new(self, @processor)
                @processor.transport = @connection
                true
            end
        end
    end
end
