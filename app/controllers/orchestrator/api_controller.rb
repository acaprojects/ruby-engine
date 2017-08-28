
module Orchestrator
    class ApiController < ::Auth::Api::Base
        protected

        # Access to the control system controller
        def control
            @@__control__ ||= ::Orchestrator::Control.instance
        end

        def prepare_json(object)
            case object
            when nil, true, false, Hash, String, Integer, Array, Float
                object
            else
                nil
            end
        end
    end
end
