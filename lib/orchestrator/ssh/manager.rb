# frozen_string_literal: true

module Orchestrator
    module Ssh
        class Manager < ::Orchestrator::Device::Manager
            def start_local(online = @settings.running)
                return false if not online
                return true if @processor

                @processor = Orchestrator::Device::Processor.new(self)
                core_start_local online # Calls on load (allows setting of tls certs)

                # After super so we can apply config like NTLM
                @connection = TransportSsh.new(self, @processor)
                @processor.transport = @connection
                true
            end
        end
    end
end
