
module Orchestrator
    class ApiController < ::Orchestrator::Base
        NAME_SORT_ASC ||= [{
            'doc.name.sort' => {
                order: :asc
            }
        }]

        protected

        # Access to the control system controller
        def control
            @@__control__ ||= ::Orchestrator::Control.instance
        end
    end
end
