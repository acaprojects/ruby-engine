# frozen_string_literal: true

require 'set'

module Orchestrator
    module Core
        class ScheduleProxy
            def initialize(thread, mod_man)
                @scheduler = thread.scheduler
                @schedules = Set.new
                @manager = mod_man
            end

            attr_reader :schedules

            def every(time, callback = nil, &block)
                add_schedule @scheduler.every(time, curry_user(callback || block))
            end

            def in(time, callback = nil, &block)
                add_schedule @scheduler.in(time, curry_user(callback || block))
            end

            def at(time, callback = nil, &block)
                add_schedule @scheduler.at(time, curry_user(callback || block))
            end

            def cron(schedule, callback = nil, timezone: nil, &block)
                add_schedule @scheduler.cron(schedule, curry_user(callback || block), timezone: timezone)
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

            def curry_user(block)
                user = @manager.current_user
                proc do |*args|
                    current_user = @manager.current_user
                    begin
                        @manager.current_user = user
                        block.call(*args)
                    ensure
                        @manager.current_user = current_user
                    end
                end
            end
        end
    end
end
