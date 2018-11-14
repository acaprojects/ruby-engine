class TriggerMailer < ApplicationMailer

    # to preview add this to your application.rb file:
    # config.action_mailer.preview_path = File.expand_path('../control/lib/mailer_previews', Rails.root)
    #
    # Then browse to: http://localhost:3000/rails/mailers/trigger_mailer/trigger_notice

    def trigger_notice(system_name, system_id, trigger_name, trigger_desc, emails, user_content)
        backoffice = Rails.configuration.orchestrator.backoffice_url

        @system_name  = system_name
        @support_url  = "#{backoffice}/#/?system=#{system_id}&tab=triggers"
        @trigger_name = trigger_name
        @trigger_desc = trigger_desc
        @user_content = user_content

        mail(
            to: emails,
            subject: "Trigger fired: #{trigger_name}"
        )
    end
end
