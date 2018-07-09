class OfflineMailerPreview < ActionMailer::Preview
    def offline_report
        OfflineMailer.offline_report('support@cotag.me, bob@jane.com')
    end
end
