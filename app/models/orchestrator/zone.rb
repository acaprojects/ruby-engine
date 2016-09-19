# frozen_string_literal: true

module Orchestrator
    class Zone < Couchbase::Model
        design_document :zone
        include ::CouchbaseId::Generator

        extend EnsureUnique
        extend Index


        attribute :name
        attribute :description
        attribute :settings,    default: lambda { {} }

        attribute :created_at,  default: lambda { Time.now.to_i }



        # Loads all the zones
        def self.all
            all(stale: false)
        end
        view :all


        ensure_unique :name, :name do |name|
            "#{name.to_s.strip.downcase}"
        end


        protected


        validates :name,  presence: true


        before_delete :remove_zone
        def remove_zone
            ::Orchestrator::Control.instance.zones.delete(self.id)
            ::Orchestrator::ControlSystem.in_zone(self.id).each do |cs|
                cs.zones.delete(self.id)
                cs.save
            end
        end

        # Expire both the zone cache and any systems that use the zone
        after_save :expire_caches
        def expire_caches
            ::Orchestrator::Control.instance.zones[self.id] = self
            ::Orchestrator::ControlSystem.in_zone(self.id).each do |cs|
                cs.expire_cache
            end
        end
    end
end
