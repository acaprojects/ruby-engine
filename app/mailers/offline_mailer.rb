require 'action_view'
class FromNow
    include ActionView::Helpers::DateHelper
end

class OfflineMailer < ApplicationMailer
    layout 'engine_mailer'

    # to preview add this to your application.rb file:
    # config.action_mailer.preview_path = File.expand_path('../ruby-engine/lib/mailer_previews', Rails.root)
    #
    # Then browse to: http://localhost:3000/rails/mailers/offline_mailer/offline_report

    def offline_report(emails)
        details = {} # Holds all the issues
        sys_names = {} # sys_id to name mappings

        # Grab system list
        Orchestrator::ControlSystem.all.each { |cs| sys_names[cs.id] = cs.name }

        # Check triggers
        sys_names.each do |sys_id, name|
            Orchestrator::TriggerInstance.for(sys_id).each do |trig|
                if trig.enabled && trig.important && trig.triggered
                    details[sys_id] ||= { name: name, offline: [], trig: [], uis: [] }
                    details[sys_id][:trig] << trig
                end
            end
        end

        # Look for offline devices
        offline = []
        Orchestrator::Module.all.each do |m|
            offline << m if m.running && !m.connected && !m.ignore_connected
        end

        # Associate devices with systems
        offline.sort_by { |o| -o.updated_at }.each do |m|
            sys_obj = Orchestrator::ControlSystem.using_module(m.id).to_a[0]
            sys_id, name = sys_obj ? [sys_obj.id, sys_obj.name] : ['unknown', 'unknown']
            details[sys_id] ||= { name: name, offline: [], trig: [], uis: [] }
            details[sys_id][:offline] << m
        end

        # Build report
        @backoffice = Rails.configuration.orchestrator.backoffice_url
        @details = details
        @from_now = FromNow.new

        emails_actual = emails.split(",").map { |email| email.strip }.reject { |email| email.empty? }

        mail(
            to: emails_actual,
            subject: "Issue Report: #{details.size} systems"
        )
    end
end
