# frozen_string_literal: true

require 'thread'
require 'singleton'

module Orchestrator; end

class Orchestrator::SystemAbstraction
    attr_reader :zones, :config

    def initialize(control_system)
        @modules = {}
        @config = control_system

        # Index triggers (exposed as __Triggers__)
        state = ::Orchestrator::ClusterState.instance
        loader = ::Orchestrator::ModuleLoader.instance
        index_module state, loader, control_system.id

        # Index the real modules
        @config.modules.each { |id| index_module(state, loader, id) }

        # Build an ordered zone cache for setting lookup
        zones = ::Orchestrator::ZoneCache.instance
        @zones = @config.zones.map { |zone_id| zones.get(zone_id) }

        # Notify the subscription service that something might have changed
        ::Orchestrator::Subscriptions.instance.reloaded_system(@config.id, self)
    end

    def get(mod, index)
        mods = @modules[mod]
        mods[index - 1] if mods
    end

    def all(mod)
        # We use the array helper here as to prevent returning nil
        ::Array(@modules[mod])
    end

    def count(name)
        mod = @modules[name]
        # nil.to_i == 0
        mod&.length.to_i
    end

    def modules
        @modules.keys
    end

    def settings
        @config.settings
    end

    protected

    def index_module(state, loader, mod_id)
        manager = loader.get(mod_id)

        if manager
            mod_name = manager.module_name
            @modules[mod_name] ||= []
            @modules[mod_name] << manager
        else
            Rails.logger.error "unable to index module #{mod_id}, system #{@config.id} may not function as expected"
        end
    end
end
