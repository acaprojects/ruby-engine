# frozen_string_literal: true

module Orchestrator
    class AccessLog < CouchbaseOrm::Base
        design_document :alog


        TTL = Rails.env.production? ? 2.weeks.to_i : 480


        belongs_to :user,    class_name: "::User"
        belongs_to :system,  class_name: "::Orchestrator::ControlSystem"
        attribute  :systems, type: Array, default: lambda { [] }

        attribute :ip,        type: String
        attribute :persisted, type: Boolean, default: false
        attribute :suspected, type: Boolean, default: false

        # Does this connection claim to be from a device
        # such as an iPad that is installed in the system
        attribute :installed_device, type: Boolean, default: false
        attribute :notes,            type: String

        attribute :created_at,      type: Integer
        attribute :ended_at,        type: Integer
        attribute :last_checked_at, type: Integer, default: 0


        def initialize(*args)
            super(*args)

            if self.created_at.nil?
                self.created_at = Time.now
            end
        end

        def save(*args, **options)
            self.last_checked_at = Time.now
            self.system_id = self.systems.first || :passive
            # Where passive means that a client authenticated with the websocket however
            # the user didn't connect to any systems. Not really the normal behaviour

            options[:ttl] = TTL unless self.persisted

            super(*args, **options)
        end
    end
end
