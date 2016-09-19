# frozen_string_literal: true

module Orchestrator
    module Logic
        class Manager < ::Orchestrator::Core::ModuleManager

            # Access to other modules in the same control system
            def system(user = nil)
                ::Orchestrator::Core::SystemProxy.new(@thread, @settings.control_system_id, self, user)
            end

            def start_local(online = @settings.running)
                return false unless online
                super online
            end
        end
    end
end
