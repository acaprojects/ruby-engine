# frozen_string_literal: true

module Orchestrator
    class AccessLog < Couchbase::Model
        design_document :alog
        include ::CouchbaseId::Generator


        TTL = Rails.env.production? ? 2.weeks.to_i : 480


        belongs_to :user,      class_name: "::User"
        belongs_to :system,    class_name: "::Orchestrator::ControlSystem"
        attribute  :systems,   default: lambda { [] }

        attribute :ip
        attribute :persisted,        default: false
        attribute :suspected,        default: false

        # Does this connection claim to be from a device
        # such as an iPad that is installed in the system
        attribute :installed_device, default: false
        attribute :notes

        attribute :created_at
        attribute :ended_at
        attribute :last_checked_at, default: 0


        def initialize(*args)
            super(*args)

            if self.created_at.nil?
                self.created_at = Time.now.to_i
            end
        end

        def save
            self.last_checked_at = Time.now.to_i
            self.system_id = self.systems.first || :passive
            # Where passive means that a client authenticated with the websocket however
            # the user didn't connect to any systems. Not really the normal behaviour

            if self.persisted
                super
            else
                super(ttl: TTL)
            end
        end
    end
end
