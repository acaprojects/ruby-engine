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

            def every(*args, &block)
                add_schedule @scheduler.every(*args, curry_user(block))
            end

            def in(*args, &block)
                add_schedule @scheduler.in(*args, curry_user(block))
            end

            def at(*args, &block)
                add_schedule @scheduler.at(*args, curry_user(block))
            end

            def cron(*args, &block)
                add_schedule @scheduler.cron(*args, curry_user(block))
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
