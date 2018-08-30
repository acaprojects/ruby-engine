# frozen_string_literal: true

require 'thread'
require 'singleton'

module Orchestrator; end
class Orchestrator::SystemCache < Orchestrator::Cache
    include Singleton

    protected

    # Load the system from the database
    def load(id)
        load_helper('System %s failed to load. System %s may not function properly', id) do
            sys = ::Orchestrator::ControlSystem.find_by_id(id)

            # Check system exists in the database
            if sys
                reactor.work { sys.deep_decrypt }.value
                ::Orchestrator::SystemAbstraction.new(sys)
            else
                nil
            end
        end
    end

    # This happens less often but it's better than failure
    def blocking_load(id)
        blocking_load_helper('System %s failed to load. System %s may not function properly', id) do
            sys = ::Orchestrator::ControlSystem.find_by_id(id)

            # Check system exists in the database
            if sys
                sys.deep_decrypt
                ::Orchestrator::SystemAbstraction.new(sys)
            else
                nil
            end
        end
    end
end
