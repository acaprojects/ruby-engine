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

            def every(time, &block)
                add_schedule @scheduler.every(time, &curry_user(block))
            end

            def in(time, &block)
                add_schedule @scheduler.in(time, &curry_user(block))
            end

            def at(time, &block)
                add_schedule @scheduler.at(time, &curry_user(block))
            end

            def cron(schedule, timezone: nil, &block)
                add_schedule @scheduler.cron(schedule, timezone: timezone, &curry_user(block))
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
                # Save the user who created the schedule
                user = @manager.current_user

                proc do |*args|
                    # Save any active users on this fiber (should be nil)
                    current_user = @manager.current_user
                    begin
                        # Set the user
                        @manager.current_user = user
                        block.call(*args)
                    rescue Exception => e
                        @manager.logger.print_error(e, 'in scheduled task')
                    ensure
                        # Restore the previous user (probably nil)
                        @manager.current_user = current_user
                    end
                end
            end
        end
    end
end
