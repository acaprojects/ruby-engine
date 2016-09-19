# frozen_string_literal: true

require 'set'
require 'addressable/uri'

module Orchestrator
    class ControlSystem < Couchbase::Model
        design_document :sys
        include ::CouchbaseId::Generator

        extend EnsureUnique
        extend Index

        
        # Allows us to lookup systems by names
        after_save      :expire_cache
        before_save     :update_features

        before_delete   :cleanup_modules
        after_delete    :expire_cache


        # Defines the default affinity for modules in this system and triggers
        # Of course it doesn't mean the module has to be located on this machine
        belongs_to :edge, class_name: 'Orchestrator::EdgeControl'


        attribute :name
        attribute :description

        # Room search meta-data
        # Building + Level are both filtered using zones
        attribute :email
        attribute :capacity,    default: 0
        attribute :features
        attribute :bookable,    default: false

        # The number of UI devices that are always available in the room
        # i.e. the number of iPads mounted on the wall
        attribute :installed_ui_devices, default: 0

        attribute :zones,       default: lambda { [] }
        attribute :modules,     default: lambda { [] }
        attribute :settings,    default: lambda { {} }

        attribute :created_at,  default: lambda { Time.now.to_i }

        # Provide a field for simplifying support
        attribute :support_url


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

        ensure_unique :name, :name do |name|
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
                (::Orchestrator::Module.find_by_id(self.modules) || []).each do |mod|
                    if mod.control_system_id
                        manager = ctrl.loaded? mod.id
                        manager.reloaded(mod) if manager
                    end
                end
            end
        end


        def self.all
            by_node(stale: false)
        end

        def self.using_module(mod_id)
            by_modules(key: mod_id, stale: false)
        end
        view :by_modules

        def self.in_zone(zone_id)
            by_zones(key: zone_id, stale: false)
        end
        view :by_zones

        def self.on_node(edge_id)
            by_node(key: edge_id, stale: false)
        end
        view :by_node


        # Methods for obtaining the modules and zones as objects
        def module_data
            (::Orchestrator::Module.find_by_id(modules) || []).collect do |mod| 
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
            ::Orchestrator::Zone.find_by_id(zones) || []
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
        validates :zones,       presence: true
        validates :edge_id,     presence: true

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
    end
end
