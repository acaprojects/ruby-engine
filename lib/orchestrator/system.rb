# frozen_string_literal: true

require 'thread'

module Orchestrator
    class System
        @@systems = Concurrent::Map.new
        @@critical = Mutex.new

        def self.get(id)
            name = id.to_sym
            system = @@systems[name]
            if system.nil?
                system = self.load(name)
            end
            return system
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
            @controller = ::Orchestrator::Control.instance

            @modules = {}
            
            # Index triggers (exposed as __Triggers__)
            index_module control_system.id

            # Index the real modules
            @config.modules.each &method(:index_module)

            # Build an ordered zone cache for setting lookup
            ctrl = ::Orchestrator::Control.instance
            zones = ctrl.zones
            @zones = []
            @config.zones.each do |zone_id|
                zone = zones[zone_id]

                if zone.nil?
                    # Try to load this zone!
                    prom = ctrl.load_zone(zone_id)
                    prom.then do |zone|
                        @config.expire_cache
                    end
                    prom.catch do |err|
                        if err == zone_id
                            # The zone no longer exists
                            ctrl.logger.warn "Stale zone, #{zone_id}, removed from system #{@config.id}"
                            @config.zones.delete(zone_id)
                            @config.save
                        else
                            # Failed to load due to an error
                            ctrl.logger.print_error err, "Zone #{zone_id} failed to load. System #{@config.id} may not function"
                        end
                    end
                else
                    @zones << zone
                end
            end

            # Inform status tracker that that the system has reloaded
            # There may have been a change in module order etc
            @controller.threads.each do |thread|
                thread.next_tick do
                    thread.observer.reloaded_system(@config.id, self)
                end
            end
        end

        def get(mod, index)
            mods = @modules[mod]
            if mods
                mods[index]
            else
                nil # As subscriptions can be made to modules that don't exist
            end
        end

        def all(mod)
            @modules[mod] || []
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
        # It's imperitive that this succeeds - sleeping on a reactor thread is preferable
        def self.load(id)
            tries = 0

            begin
                @@critical.synchronize {
                    system = @@systems[id]
                    return system unless system.nil?

                    sys = ControlSystem.find_by_id(id.to_s)
                    if sys.nil?
                        return nil
                    else
                        system = System.new(sys)
                        @@systems[id] = system
                    end
                    return system
                }
            rescue => err
                if tries <= 2
                    sleep 0.5
                    tries += 1
                    retry
                else
                    error = "System #{id} failed to load. System #{id} may not function properly"
                    ctrl.logger.print_error err, error
                    raise error
                end
            end
        end

        def index_module(mod_id)
            manager = @controller.loaded?(mod_id)
            if manager
                mod_name = if manager.settings.custom_name.nil?
                    manager.settings.dependency.module_name.to_sym
                else
                    manager.settings.custom_name.to_sym
                end
                @modules[mod_name] ||= []
                @modules[mod_name] << manager
            end
        end
    end
end
