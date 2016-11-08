# frozen_string_literal: true

module Orchestrator
    class Zone < CouchbaseOrm::Base
        design_document :zone


        attribute :name,        type: String
        attribute :description, type: String
        attribute :settings,    type: Hash,    default: lambda { {} }

        attribute :created_at,  type: Integer, default: lambda { Time.now }


        # Loads all the zones
        view :all


        ensure_unique :name do |name|
            "#{name.to_s.strip.downcase}"
        end


        def systems
            ::Orchestrator::ControlSystem.in_zone(self.id)
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
    end
end
