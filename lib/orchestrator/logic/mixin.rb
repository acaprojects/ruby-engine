# frozen_string_literal: true

module Orchestrator
    module Logic
        module Mixin
            include ::Orchestrator::Core::Mixin

            def system
                @__config__.system(current_user)
            end
        end
    end
end
