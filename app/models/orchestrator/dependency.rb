# frozen_string_literal: true

require 'set'

module Orchestrator
    class Dependency < CouchbaseOrm::Base
        design_document :dep


        after_save     :update_modules
        before_destroy :cleanup_modules


        ROLES = Set.new([:ssh, :device, :service, :logic])


        attribute :name,        type: String
        attribute :role,        type: String
        attribute :description, type: String
        attribute :default      # default data (port or URI)

        # Override default role accessors
        def role
            @role ||= self[:role].to_sym if self[:role]
        end
        def role=(name)
            @role = name.to_sym
            self[:role] = name
        end

        attribute :class_name,  type: String
        attribute :module_name, type: String
        attribute :settings,    type: Hash,    default: proc { {} }
        attribute :created_at,  type: Integer, default: proc { Time.now }

        # Don't include this module in statistics or disconnected searches
        # Might be a device that commonly goes offline (like a PC or Display that only supports Wake on Lan)
        attribute :ignore_connected, type: Boolean, default: false


        # Find the modules that rely on this dependency
        def modules
            ::Orchestrator::Module.dependent_on(self.id)
        end

        def default_port=(port)
            self.role = :device
            self.default = port
        end

        def default_uri=(uri)
            self.role = :service
            self.default = uri
        end


        protected


        # Validations
        validates :name,            presence: true
        validates :class_name,      presence: true
        validates :module_name,     presence: true
        validate  :role_exists


        def role_exists
            if self.role && ROLES.include?(self.role.to_sym)
                self.role = self.role.to_s
            else
                errors.add(:role, 'is not valid')
            end
        end

        # Delete all the module references relying on this dependency
        def cleanup_modules
            modules.each do |mod|
                mod.destroy!
            end
        end

        # Reload all modules to update their settings
        def update_modules
            ctrl = ::Orchestrator::Control.instance
            return unless ctrl.ready

            dep = self
            mod_found = false

            modules.stream do |mod|
                mod_found = true
                mod.dependency = dep # Otherwise this will hit the database again
                manager = ctrl.loaded? mod.id
                manager.reloaded(mod) if manager
            end
            ctrl.clear_cache if mod_found
        end
    end
end
