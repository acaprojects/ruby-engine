# frozen_string_literal: true

require 'thread'
require 'singleton'

module Orchestrator; end
class Orchestrator::DependencyCache < Orchestrator::Cache
    include Singleton

    # This caches the database entries
    # The Dependency Manager manages loading ruby classes

    protected

    # Load the zone from the database
    def load(id)
        load_helper('Dependency %s failed to load.', id) do
            dep = ::Orchestrator::Zone.find_by_id(id)

            if dep
                reactor.work { dep.deep_decrypt }.value
                dep
            else
                nil
            end
        end
    end

    # This happens less often but it's better than failure
    def blocking_load(id)
        blocking_load_helper('Dependency %s failed to load.', id) do
            dep = ::Orchestrator::Zone.find_by_id(id)

            if dep
                dep.deep_decrypt
                dep
            else
                nil
            end
        end
    end
end
