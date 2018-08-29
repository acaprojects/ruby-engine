# frozen_string_literal: true

require 'thread'
require 'singleton'

module Orchestrator; end

class Orchestrator::SystemAbstraction
    attr_reader :zones, :config

    def initialize(control_system)
        @state = ::Orchestrator::ClusterState.instance
        @modules = {}

        # Cache decrypted settings
        @config = control_system
        @config.deep_decrypt

        # Index triggers (exposed as __Triggers__)
        index_module control_system.id, true

        # Index the real modules
        @config.modules.each { |id| index_module(id) }

        # Build an ordered zone cache for setting lookup
        zones = @@ctrl.zones
        @zones = []
        @config.zones.each do |zone_id|
            zone = zones[zone_id]

            if zone.nil?
                begin
                    @zones << @@ctrl.load_zone(zone_id)
                    @config.expire_cache
                rescue Libcouchbase::Error::KeyNotFound => e
                    @@ctrl.logger.warn "Stale zone, #{zone_id}, removed from system #{@config.id}"
                    @config.zones.delete(zone_id)
                    @config.save
                rescue => e
                    # Failed to load due to an error
                    @@ctrl.logger.print_error err, "Zone #{zone_id} failed to load. System #{@config.id} may not function correctly"
                end
            else
                @zones << zone
            end
        end

        @@ctrl.threads.each do |thread|
            thread.next_tick do
                thread.observer.reloaded_system(@config.id, self)
            end
        end
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
        Array(@modules[mod])
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

    def index_module(mod_id, trigger = false)
        manager = @@ctrl.loaded?(mod_id)
        manager = @@remote_modules[mod_id] unless manager

        # Failover hosts have a local copy of the remote hosts status variables
        # So binding and monitoring is simplified.
        if manager.nil?
            begin
                if trigger
                    node = @@ctrl.get_node(@config.edge_id)

                    unless node.should_run_on_this_host || node.is_failover_host
                        manager = Remote::Manager.new(@config)
                        @@remote_modules[mod_id] = manager
                    end
                elsif !trigger
                    settings = ::Orchestrator::Module.find_by_id(mod_id)

                    if settings
                        node = @@ctrl.get_node(settings.edge_id)

                        unless node.should_run_on_this_host || node.is_failover_host
                            manager = Remote::Manager.new(settings)
                            @@remote_modules[mod_id] = manager
                        end
                    else
                        @@ctrl.logger.error "unable to index module #{mod_id} in system #{@config.id}, module not found!"
                    end
                end
            rescue => e
                @@ctrl.logger.print_error e, "failure initializing remote manager"
            end
        end

        if manager
            mod_name = if manager.settings.custom_name.present?
                manager.settings.custom_name.to_sym
            else
                manager.settings.dependency.module_name.to_sym
            end
            @modules[mod_name] ||= []
            @modules[mod_name] << manager
        else
            @@ctrl.logger.warn "unable to index module #{mod_id}, system #{@config.id} may not function as expected"
        end
    end
end
