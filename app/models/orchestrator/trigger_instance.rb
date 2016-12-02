# frozen_string_literal: true

require 'securerandom'

module Orchestrator
    class TriggerInstance < CouchbaseOrm::Base
        design_document :trig


        belongs_to :control_system, :class_name => "Orchestrator::ControlSystem"
        belongs_to :trigger,        :class_name => "Orchestrator::Trigger"

        attribute :created_at, type: Integer, default: lambda { Time.now }
        attribute :updated_at, type: Integer, default: lambda { Time.now }

        attribute :enabled,    type: Boolean, default: true
        attribute :triggered,  type: Boolean, default: false
        attribute :important,  type: Boolean, default: false

        attribute :override,       type: Hash,    default: lambda { {} }
        attribute :webhook_secret, type: String,  default: lambda { SecureRandom.hex }
        attribute :trigger_count,  type: Integer, default: 0


        before_destroy :unload
        after_save     :load


        # ----------------
        # PARENT ACCESSORS
        # ----------------
        def name
            trigger.name
        end

        def description
            trigger.description
        end

        def conditions
            trigger.conditions
        end

        def actions
            trigger.actions
        end

        def debounce_period
            trigger.debounce_period
        end

        def binding
            return @binding if @binding || self.id.nil?

            @binding = String.new('t')
            self.id.each_byte do |byte|
                @binding << byte.to_s(16)
            end
            @binding
        end


        # ------------
        # VIEWS ACCESS
        # ------------
        # Helper method: for(sys_id)
        index_view :control_system_id, find_method: :for

        # Finds all the instances belonging to a particular trigger
        # Helper method: of(trig_id)
        index_view :trigger_id, find_method: :of


        # ---------------
        # JSON SERIALISER
        # ---------------
        DEFAULT_JSON_METHODS = {
            methods: [
                :name,
                :description,
                :conditions,
                :actions,
                :binding
            ].freeze
        }.freeze
        def serializable_hash(options = {})
            options = DEFAULT_JSON_METHODS.merge(options)
            super(options)
        end


        # --------------------
        # START / STOP HELPERS
        # --------------------
        def load
            if @ignore_update == true
                @ignore_update = false
            else
                mod_man = get_module_manager
                mod = mod_man.instance if mod_man

                if mod_man && mod
                    trig = self
                    mod_man.thread.schedule do
                        mod.reload trig
                    end
                end
            end
        end

        def ignore_update
            @ignore_update = true
        end

        def unload
            mod_man = get_module_manager
            mod = mod_man.instance if mod_man

            if mod_man && mod
                trig = self
                old_id = trig.id # This is removed once delete has completed
                mod_man.thread.schedule do
                    mod.remove old_id
                end
            end
        end


        protected


        def get_module_manager
            ::Orchestrator::Control.instance.loaded?(self.control_system_id)
        end


        # -----------
        # VALIDATIONS
        # -----------
        # Ensure the models exist in the database
        validates :control_system, presence: true
        validates :trigger,        presence: true
    end
end
