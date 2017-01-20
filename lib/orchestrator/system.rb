# frozen_string_literal: true

require 'thread'


# NOTE:: Changes here should have corresponding changes made to the remote version
# See class ::Orchestrator::Remote::System


module Orchestrator
    class System
        @@remote_modules = Concurrent::Map.new
        @@systems = Concurrent::Map.new
        @@critical = Mutex.new
        @@ctrl = ::Orchestrator::Control.instance


        def self.get(id)
            name = id.to_sym
            @@systems[name] || self.load(name)
        end

        def self.expire(id)
            @@systems.delete(id.to_sym)
        end

        def self.clear_cache
            @@critical.synchronize {
                @@systems = Concurrent::Map.new
            }
        end


        attr_reader :zones, :config


        def initialize(control_system)
            @config = control_system
            @modules = {}

            # Index triggers (exposed as __Triggers__)
            index_module control_system.id, true

            # Index the real modules
            @config.modules.each &method(:index_module)

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
            mod.nil? ? 0 : mod.length
        end

        def modules
            @modules.keys
        end

        def settings
            @config.settings
        end


        protected


        # looks for the system in the database
        # It's imperitive that this succeeds
        def self.load(id)
            tries = 0

            begin
                @@critical.synchronize {
                    system = @@systems[id]
                    return system if system

                    sys = ControlSystem.find_by_id(id.to_s)
                    return nil unless sys

                    system = System.new(sys)

                    @@systems[id] = system
                    return system
                }
            rescue => err
                if tries <= 3
                    # Sleep the current reactor fiber
                    reactor.sleep 200
                    tries += 1
                    retry
                else
                    error = "System #{id} failed to load. System #{id} may not function properly"
                    @@ctrl.logger.print_error err, error
                    raise error
                end
            end
        end

        def index_module(mod_id, trigger = false)
            manager = @@ctrl.loaded?(mod_id)
            manager = @@remote_modules[mod_id] unless manager

            # Failover hosts have a local copy of the remote hosts status variables
            # So binding and monitoring is simplified.
            if manager.nil?
                if trigger
                    node = @@ctrl.get_node(@config.edge_id)

                    unless node.should_run_on_this_host || node.is_failover_host
                        manager = Remote::Manager.new(@config)
                        @@remote_modules[mod_id] = manager
                    end
                elsif !trigger
                    settings = ::Orchestrator::Module.find_by_id(mod_id)
                    node = @@ctrl.get_node(settings.edge_id)

                    unless node.should_run_on_this_host || node.is_failover_host
                        manager = Remote::Manager.new(settings)
                        @@remote_modules[mod_id] = manager
                    end
                end
            end

            if manager
                mod_name = if manager.settings.custom_name.nil?
                    manager.settings.dependency.module_name.to_sym
                else
                    manager.settings.custom_name.to_sym
                end
                @modules[mod_name] ||= []
                @modules[mod_name] << manager
            else
                @@ctrl.logger.warn "unable to index module #{mod_id}, system may not function as expected"
            end
        end
    end
end
