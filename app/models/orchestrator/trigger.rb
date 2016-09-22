# frozen_string_literal: true

require 'set'

module Orchestrator
    class Trigger < Couchbase::Model
        design_document :trigger
        include ::CouchbaseId::Generator

        attribute :name
        attribute :description
        attribute :created_at,  default: lambda { Time.now.to_i }

        attribute :conditions
        attribute :actions,  default: lambda { [] }

        # in seconds
        attribute :debounce_period, default: 0


        protected


        before_delete :cleanup_instances
        def cleanup_instances
            TriggerInstance.of(self.id).each do |trig|
                trig.delete
            end
        end

        after_save :reload_all
        def reload_all
            TriggerInstance.of(self.id).each do |trig|
                trig.load
            end
        end

        # -----------
        # VALIDATIONS
        # -----------
        validates :name, presence: true

        validate  :condition_list
        validate  :action_list


        KEYS = Set.new([
            :equal, :not_equal, :greater_than, :greater_than_or_equal,
            :less_than, :less_than_or_equal, :and, :or, :exclusive_or
        ])
        CONST_KEYS =  Set.new([:at, :cron])
        def condition_list
            if self.conditions
                valid = true
                self.conditions.each do |cond|
                    if cond.length < 3
                        valid = CONST_KEYS.include?(cond[0].to_sym)
                    else
                        valid = value?(cond[0]) && cond[1] && KEYS.include?(cond[1].to_sym) && value?(cond[2])
                    end
                    break if not valid
                end

                if not valid
                    errors.add(:conditions, 'are not all valid')
                end
            end
        end

        STATUS_KEYS = Set.new([:mod, :index, :status, :keys])
        # TODO:: Should also check types
        def value?(strong_val)
            val = strong_val.to_h.deep_symbolize_keys
            if val.has_key?(:const)
                # Should only store the constant
                val.keep_if { |k, _| k == :const }
                true
            else
                # Should be a status variable
                val.keep_if { |k, _| STATUS_KEYS.include? k }
                val[:index].is_a?(Integer) && val.has_key?(:mod) && val.has_key?(:status)
            end
        end


        def action_list
            if self.actions
                valid = true
                self.actions.each do |act|
                    valid = check_action(act)
                end

                if not valid
                    errors.add(:actions, 'are not all valid')
                end
            end
        end

        ACTION_KEYS = Set.new([:type, :mod, :index, :func, :args, :emails, :content])
        def check_action(strong_act)
            act = strong_act.to_h.deep_symbolize_keys
            act.keep_if { |k, _| ACTION_KEYS.include? k }

            return false if act.empty? || act[:type].nil?

            case act[:type].to_sym
            when :exec
                act[:index].is_a?(Integer) && act.has_key?(:mod) && act.has_key?(:func) && act[:args].is_a?(Array)
            when :email
                if act[:emails]
                    mail = act[:emails] = act[:emails].gsub(/\s+/, '')
                    result = mail.split(",").map { |email| email.strip }.reject { |email| email.empty? }
                    !result.empty?
                else
                    false
                end
            else
                false
            end
        end
    end
end
