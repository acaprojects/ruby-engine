# frozen_string_literal: true

require 'set'

module Orchestrator
    module Core
        class ScheduleProxy
            def initialize(thread)
                @scheduler = thread.scheduler
                @schedules = Set.new
            end

            attr_reader :schedules

            def every(*args, &block)
                add_schedule @scheduler.every(*args, &block)
            end

            def in(*args, &block)
                add_schedule @scheduler.in(*args, &block)
            end

            def at(*args, &block)
                add_schedule @scheduler.at(*args, &block)
            end

            def cron(*args, &block)
                add_schedule @scheduler.cron(*args, &block)
            end

            def clear
                @schedules.each do |schedule|
                    schedule.cancel
                end
            end


            protected


            def add_schedule(schedule)
                @schedules.add(schedule)
                schedule.finally do
                    @schedules.delete(schedule)
                end
                schedule
            end
        end
    end
end
