
module Orchestrator
    class ApiController < ::Auth::Api::Base
        protected

        # Access to the control system controller
        def control
            @@__control__ ||= ::Orchestrator::Control.instance
        end

        def prepare_json(object)
            case object
            when nil, true, false, Hash, String, Integer, Array, Float, Symbol
                object
            else
                if object.respond_to? :to_h
                    object.to_h
                elsif object.respond_to? :to_json
                    object.to_json
                elsif object.respond_to? :to_s
                    object.to_s
                else
                    nil
                end
            end
        end
    end
end
