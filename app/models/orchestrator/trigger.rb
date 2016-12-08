# frozen_string_literal: true

# Prevent has_many load warning
require File.expand_path('../trigger_instance', __FILE__)
require 'set'

module Orchestrator
    class Trigger < CouchbaseOrm::Base
        design_document :trigger

        attribute :name,            type: String
        attribute :description,     type: String
        attribute :created_at,      type: Integer, default: lambda { Time.now }

        attribute :conditions,      type: Array
        attribute :actions,         type: Array,   default: lambda { [] }

        # in seconds
        attribute :debounce_period, type: Integer, default: 0
        attribute :important,       type: Boolean, default: false


        has_many :trigger_instances, dependent: :destroy, class_name: "Orchestrator::TriggerInstance"


        protected


        after_save :reload_all
        def reload_all
            trigger_instances.each do |trig|
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
        CONST_KEYS =  Set.new([:at, :cron, :webhook])
        def condition_list
            if self.conditions
                valid = true
                self.conditions.each do |cond|
                    if cond.length < 3
                        valid = CONST_KEYS.include?(cond[0].to_sym)
                    else
                        valid = value?(cond[0]) && KEYS.include?(cond[1].to_sym) && value?(cond[2])
                    end
                    break if not valid
                end

                if not valid
                    errors.add(:conditions, 'are not all valid')
                end
            else
                self.conditions = []
            end
        end

        STATUS_KEYS = Set.new([:mod, :index, :status, :keys])
        def value?(strong_val)
            val = strong_val.to_h.deep_symbolize_keys
            if val.has_key?(:const)
                # Should only store the constant
                val.keep_if { |k, _| k == :const }
                true
            else
                # Should be a status variable
                val.delete(:keys) unless val[:keys].is_a?(Array)
                val.keep_if { |k, v| STATUS_KEYS.include?(k) && v.present? }
                val[:keys].map { |v| v.strip }.delete_if { |v| v.empty? } if val[:keys]
                val[:index].is_a?(Integer) && val[:mod].is_a?(String) && val[:status].is_a?(String)
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
            else
                self.actions = []
            end
        end

        ACTION_KEYS = Set.new([:type, :mod, :index, :func, :args, :emails, :content])
        def check_action(strong_act)
            act = strong_act.to_h.deep_symbolize_keys
            act.keep_if { |k, v| ACTION_KEYS.include?(k) && v.present? }

            return false if act.empty? || act[:type].nil?

            case act[:type].to_sym
            when :exec
                act[:index].is_a?(Integer) && act.has_key?(:mod) && act.has_key?(:func) && act[:args].is_a?(Array)
            when :email
                if act[:emails]
                    mail = act[:emails].gsub(/\s+/, '')
                    result = mail.split(",").reject { |email| email.empty? }
                    act[:emails] = result.join(',')
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
