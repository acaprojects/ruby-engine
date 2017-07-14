# frozen_string_literal: true

module Orchestrator
    module Ssh
        class Manager < ::Orchestrator::Device::Manager
            def start_local(online = @settings.running)
                return false if not online
                return true if @processor

                @processor = Orchestrator::Device::Processor.new(self)
                core_start_local online # Calls on load (allows setting of tls certs)

                @username, @ssh_settings = get_ssh_settings

                # After super so we can apply config like NTLM
                @connection = TransportSsh.new(self, @processor)
                @processor.transport = @connection
                true
            end

            attr_reader :username, :ssh_settings

            def reloaded(mod)
                super(mod)

                # Check if the SSH settings have changed
                @thread.schedule do
                    username, ssh_settings = get_ssh_settings
                    if username != @username || @ssh_settings != ssh_settings
                        @username = username
                        @ssh_settings = ssh_settings

                        if @processor&.connected?
                            @logger.debug 'SSH setting change detected. Reconnecting...'
                            @connection.disconnect
                        end
                    end
                end
            end

            def get_ssh_settings
                ssh_settings = (decrypt(:ssh) || {}).symbolize_keys
                ssh_settings.merge!({
                    port: @settings.port,
                    non_interactive: true,
                    logger: @logger
                })
                username = ssh_settings.delete(:username) || ''

                [username, ssh_settings]
            end
        end
    end
end
