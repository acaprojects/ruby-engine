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
        modules = ::Orchestrator::ModuleLoader.instance
        index_module state, modules, control_system.id, true

        # Index the real modules
        @config.modules.each { |id| index_module(state, modules, id) }

        # Build an ordered zone cache for setting lookup
        zones = ::Orchestrator::ZoneCache.instance
        @zones = @config.zones.map { |zone_id| zones.get(zone_id) }

        ::Orchestrator::Subscriptions.reloaded_system(@config.id, self)
    end

    def get(mod, index)
        mods = @modules[mod]
        if mods
            mods[index - 1]
        else
            nil # As subscriptions can be made to modules that don't exist
        end
    end

    def all(mod)
        ::Array(@modules[mod])
    end

    def count(name)
        mod = @modules[name.to_sym]
        mod&.length || 0
    end

    def modules
        @modules.keys
    end

    def settings
        @config.settings
    end

    protected

    def index_module(state, modules, mod_id)
        manager = modules.get(mod_id)

        if manager
            # TODO:: implement manager.module_name
            mod_name = manager.module_name
            @modules[mod_name] ||= []
            @modules[mod_name] << manager
        else
            Rails.logger.error "unable to index module #{mod_id}, system #{@config.id} may not function as expected"
        end
    end
end
