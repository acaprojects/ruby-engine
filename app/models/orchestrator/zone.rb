# frozen_string_literal: true

module Orchestrator
    class Zone < CouchbaseOrm::Base
        design_document :zone


        attribute :name,        type: String
        attribute :description, type: String
        attribute :settings,    type: Hash,    default: lambda { {} }
        attribute :triggers,    type: Array,   default: lambda { [] }

        attribute :created_at,  type: Integer, default: lambda { Time.now }

        has_many :trigger_instances, dependent: :destroy, class_name: "Orchestrator::TriggerInstance"


        # Loads all the zones
        view :all


        ensure_unique :name do |name|
            "#{name.to_s.strip.downcase}"
        end


        def systems
            ::Orchestrator::ControlSystem.in_zone(self.id)
        end

        def trigger_data
            if triggers.empty?
                []
            else
                Array(::Orchestrator::Trigger.find_by_id(triggers))
            end
        end


        protected


        validates :name,  presence: true


        before_destroy :remove_zone
        def remove_zone
            zone_cache.delete(self.id)
            systems.each do |cs|
                cs.zones.delete(self.id)
                cs.save!
            end
        end

        # Expire both the zone cache and any systems that use the zone
        after_save :expire_caches
        def expire_caches
            zone_cache[self.id] = self
            systems.each do |cs|
                cs.expire_cache
            end
        end

        def zone_cache
            ::Orchestrator::Control.instance.zones
        end


        # =======================
        # Zone Trigger Management
        # =======================
        before_save :check_triggers
        def check_triggers
            if self.triggers_changed?
                previous = Array(self.triggers_was)
                current  = self.triggers

                @remove_triggers = previous - current
                @add_triggers = current - previous

                @update_systems = @remove_triggers.present? || @add_triggers.present?
            else
                @update_systems = false
            end
            nil
        end

        after_save :update_triggers
        def update_triggers
            return unless @update_systems
            if @remove_triggers.present?
                self.trigger_instances.stream do |trig|
                    trig.destroy if @remove_triggers.include?(trig.trigger_id)
                end
            end

            if @add_triggers.present?
                systems.stream do |sys|
                    @add_triggers.each do |trig_id|
                        inst = ::Orchestrator::TriggerInstance.new
                        inst.control_system = sys
                        inst.trigger_id = trig_id
                        inst.zone_id = self.id
                        inst.save
                    end
                end
            end
            nil
        end
    end
end
