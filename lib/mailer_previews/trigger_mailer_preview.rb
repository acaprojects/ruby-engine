class TriggerMailerPreview < ActionMailer::Preview
    def trigger_notice
        TriggerMailer.trigger_notice('Example System Name', 'sys_1-1B', 'Lamp Hours over 3000', "Lamps are old\nmax age 3500\nnot much time", 'support@cotag.me,bob@jane.com', "Please replace the lamps\nin the next two days")
    end
end
