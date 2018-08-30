# frozen_string_literal: true

require 'thread'
require 'singleton'

module Orchestrator; end
class Orchestrator::ZoneCache < Orchestrator::Cache
    include Singleton

    protected

    # Load the zone from the database
    def load(id)
        load_helper('Zone %s failed to load.', id) do
            zone = ::Orchestrator::Zone.find_by_id(id)

            if zone
                reactor.work { zone.deep_decrypt }.value
                zone
            else
                nil
            end
        end
    end

    # This happens less often but it's better than failure
    def blocking_load(id)
        blocking_load_helper('Zone %s failed to load.', id) do
            zone = ::Orchestrator::Zone.find_by_id(id)

            if zone
                zone.deep_decrypt
                zone
            else
                nil
            end
        end
    end
end
