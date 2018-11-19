# frozen_string_literal: true

module Orchestrator
    module Triggers
        class Manager < ::Orchestrator::Logic::Manager
            # Main difference between a regular logic module and the trigger module
            # is that there is no database entry
            NOT_IMPLEMENTED = 'not implemented by design'

            def setting(name)
                raise NOT_IMPLEMENTED
            end

            def define_setting(name, value)
                raise NOT_IMPLEMENTED
            end

            def update_connected_status; end
            def update_running_status(running); end
            def reloaded(mod, code_update: false); end

            # @settings (system model) used in: @logger, subscribe
        end
    end
end
