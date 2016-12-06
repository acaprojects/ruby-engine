# frozen_string_literal: true

require 'set'
require 'addressable/uri'

module Orchestrator
    class ControlSystem < CouchbaseOrm::Base
        design_document :sys


        # Allows us to lookup systems by names
        after_save     :expire_cache
        before_save    :update_features

        before_destroy :cleanup_modules
        after_destroy  :expire_cache


        # Defines the default affinity for modules in this system and triggers
        # Of course it doesn't mean the module has to be located on this machine
        belongs_to :edge, class_name: 'Orchestrator::EdgeControl'


        attribute :name,        type: String
        attribute :description, type: String

        # Room search meta-data
        # Building + Level are both filtered using zones
        attribute :email,    type: String
        attribute :capacity, type: Integer, default: 0
        attribute :features, type: String
        attribute :bookable, type: Boolean, default: false

        # The number of UI devices that are always available in the room
        # i.e. the number of iPads mounted on the wall
        attribute :installed_ui_devices, type: Integer, default: 0

        attribute :zones,       type: Array,   default: lambda { [] }
        attribute :modules,     type: Array,   default: lambda { [] }
        attribute :settings,    type: Hash,    default: lambda { {} }

        attribute :created_at,  type: Integer, default: lambda { Time.now }

        # Provide a field for simplifying support
        attribute :support_url, type: String


        # Used in triggers::manager for accssing a system proxy
        def control_system_id
            self.id
        end

        # Returns the node currently running this module
        def node
            # NOTE:: Same function in module.rb
            @nodes ||= Control.instance.nodes
            @node_id ||= self.edge_id.to_sym
            @nodes[@node_id]
        end

        ensure_unique :name do |name|
            "#{name.to_s.strip.downcase}"
        end

        def expire_cache(noUpdate = nil)
            ::Orchestrator::System.expire(self.id || @old_id)
            ctrl = ::Orchestrator::Control.instance

            # If not deleted and control is running
            # then we want to trigger updates on the logic modules
            if !@old_id && noUpdate.nil? && ctrl.ready
                # Start the triggers if not already running (must occur on the same thread)
                cs = self
                ctrl.reactor.schedule do
                    ctrl.nodes[cs.edge_id.to_sym].load_triggers_for(cs)
                end

                # Reload the running modules
                Array(::Orchestrator::Module.find_by_id(self.modules)).each do |mod|
                    if mod.control_system_id
                        manager = ctrl.loaded? mod.id
                        manager.reloaded(mod) if manager
                    end
                end
            end
        end


        index_view :modules, find_method: :using_module, validate: false
        index_view :zones,   find_method: :in_zone

        def self.all
            by_edge_id
        end
        index_view :edge_id, find_method: :on_node


        # Methods for obtaining the modules and zones as objects
        def module_data
            Array(::Orchestrator::Module.find_by_id(modules)).collect do |mod| 
                mod.as_json({
                    include: {
                        dependency: {
                            only: [:name, :module_name]
                        }
                    }
                })
            end
        end

        def zone_data
            Array(::Orchestrator::Zone.find_by_id(zones))
        end


        # Triggers
        def triggers
            TriggerInstance.for(self.id)
        end

        # For trigger logic module compatibility
        def running; true; end
        def custom_name; :__Triggers__; end


        protected


        # Zones and settings are only required for confident coding
        validates :name,        presence: true

        validates :capacity, numericality: { only_integer: true }
        validates :bookable, inclusion:    { in: [true, false]  }

        validate  :support_link

        def support_link
            if self.support_url.nil? || self.support_url.empty?
                self.support_url = nil
            else
                begin
                    url = Addressable::URI.parse(self.support_url)
                    url.scheme && url.host && url
                rescue
                    errors.add(:support_url, 'is an invalid URI')
                end
            end
        end


        # 1. Find systems that have each of the modules specified
        # 2. If this is the last system we remove the modules
        def cleanup_modules
            ctrl = ::Orchestrator::Control.instance

            self.modules.each do |mod_id|
                systems = ControlSystem.using_module(mod_id).fetch_all

                if systems.length <= 1
                    # We don't use the model's delete method as it looks up control systems
                    ctrl.unload(mod_id)
                    ::Orchestrator::Module.bucket.delete(mod_id, {quiet: true})
                end
            end
            
            # Unload the triggers
            ctrl.unload(self.id)

            # delete all the trigger instances (remove directly as before_delete is not required)
            bucket = ::Orchestrator::TriggerInstance.bucket
            TriggerInstance.for(self.id).each do |trig|
                bucket.delete(trig.id)
            end

            # Prevents reload for the cache expiry
            @old_id = self.id
        end

        def update_features
            return unless self.bookable

            ctrl = ::Orchestrator::Control.instance
            if ctrl.ready
                system = System.get(self.id)
                if system
                    mods = system.modules
                    mods.delete(:__Triggers__)
                    self.features = mods.join ' '
                end

                if self.settings[:extra_features].present?
                    self.features = "#{self.features} #{self.settings[:extra_features]}"
                end
            end
        end


        # =======================
        # Zone Trigger Management
        # =======================
        before_save :check_zones
        def check_zones
            if self.zones_changed?
                previous = Array(self.zones_was)
                current  = self.zones

                @remove_zones = previous - current
                @add_zones = current - previous

                @update_triggers = @remove_zones.present? || @add_zones.present?
            else
                @update_triggers = false
            end
            nil
        end

        after_save :update_triggers
        def update_triggers
            return unless @update_triggers

            if @remove_zones.present?
                trigs = triggers.to_a

                @remove_zones.collect { |zone_id|
                    ::Orchestrator::Zone.find(zone_id)
                }.each do |zone|
                    zone.triggers.each do |trig_id|
                        trigs.each do |trig|
                            if trig.trigger_id == trig_id && trig.zone_id == zone.id
                                trig.destroy
                            end
                        end
                    end
                end
            end

            @add_zones.each do |zone_id|
                zone = ::Orchestrator::Zone.find(zone_id)
                zone.triggers.each do |trig_id|
                    inst = ::Orchestrator::TriggerInstance.new
                    inst.control_system = self
                    inst.trigger_id = trig_id
                    inst.zone_id = zone.id
                    inst.save
                end
            end
            nil
        end
    end
end
