# frozen_string_literal: true

module Orchestrator
    module Triggers
        class State
            include ::Orchestrator::Constants


            def initialize(trigger, scheduler, callback, logger = nil)
                @scheduler = scheduler
                @callback = callback
                @logger = logger
                @enabled  = false

                # condition = [:value, :comparison, :value]
                # * value = {mod:, index:, status:, keys: []}
                # * value = {const: }
                # * comparison = :equal, :not_equal, :greater_than
                # special comparison values: :at [time string], :cron [cron string]

                @values = {}         # Last known status values
                @subscriptions = []  # Modules we need to subscribe to
                @conditions = []     # Pre-processed list of conditions
                @schedules = {}      # References to schedules

                @id = trigger.id
                @triggered = trigger.triggered
                @override = trigger.override
                @webhook_secret = trigger.webhook_secret

                conditions = trigger.conditions
                conditions.each_with_index do |cond, index|
                    extract_condition(cond, index)
                end
            end


            # The trigger modules needs to know what to subscribe to
            attr_reader   :subscriptions, :triggered


            # Update a status variable
            def set_value(info)
                lookup = key(info[:mod_name], info[:index], info[:status])
                @values[lookup] = info.value

                check_conditions if @enabled
            end

            def enabled(state)
                @enabled = state
                check_conditions if @enabled
            end

            # Loop through the conditions and check if they are all true
            # If so then call the callback
            def check_conditions
                result = true

                begin
                    @conditions.each do |cond|
                        val1 = get_value cond[0]
                        operator = cond[1]
                        val2 = get_value cond[2]

                        result = __send__(operator, val1, val2)
                        break unless result
                    end
                rescue => e
                    # warn of potential issue here
                    @logger.warn "#{e.message}\nerror comparing values for trigger #{@id}" if @logger
                    result = false
                end

                @callback.call(@id, result) if @enabled && result != @triggered
                @triggered = result
                result
            end

            # Called once this state isn't needed anymore
            # Cancels the schedules
            def destroy
                @schedules.each_value(&:cancel)
                @enabled = false
            end

            # Triggered by a call from the API
            def webhook
                return if @schedules[@webhook_secret] || !@enabled

                @values[@webhook_secret] = true
                check_conditions

                # 1min window of value high
                @schedules[@webhook_secret] = @scheduler.in(59000) do
                    @schedules.delete(@webhook_secret)
                    @values[@webhook_secret] = false
                    check_conditions if @enabled
                end
            end


            protected


            def extract_condition(cond, index)
                if cond.length < 3
                    cond_type = cond[0].to_sym
                    if cond_type == :webhook
                        lookup = @webhook_secret
                    else # Schedule type
                        lookup = :"schedule_#{index}"

                        # cond == [at|cron, value]
                        cond1 = cond[1]
                        id = cond1[:value_id]
                        cond1 = @override[id] || cond1 if id
                        __send__(cond_type, lookup, cond1)
                    end

                    value1 = {lookup: lookup}
                    comparison = :equal

                    # Second value is always true
                    value2 = extract_value({const: true}, index)
                else
                    # Comparison type
                    cond0 = cond[0]
                    id = cond0[:value_id]
                    cond0 = @override[id] || cond0 if id
                    value1 = extract_value(cond0, index)

                    comparison = cond[1].to_sym

                    cond2 = cond[2]
                    id = cond2[:value_id]
                    cond2 = @override[id] || cond2 if id
                    value2 = extract_value(cond2, index)
                end

                @conditions << [value1, comparison, value2]
            end

            # Provides a simple value lookup
            def extract_value(val, index)
                if val.has_key?(:const)
                    lookup = :"const_#{index}"
                    @values[lookup] = val[:const]

                    {lookup: lookup}
                else
                    lookup = key(val[:mod], val[:index], val[:status])
                    keys = val[:keys]

                    if not @values.has_key?(lookup)
                        @values[lookup] = nil
                        @subscriptions << val
                    end

                    {lookup: lookup, keys: keys}
                end
            end

            def key(mod, index, status)
                :"#{mod}_#{index}.#{status}"
            end

            # Extracts the current value of a condition variable
            def get_value(val_key)
                value = @values[val_key[:lookup]]

                sub_keys = val_key[:keys]
                if sub_keys.present?
                    begin
                        value = sub_keys.reduce(value) do |sub_val, key|
                            if sub_val.is_a? Array
                                sub_val[key.to_i]
                            else
                                sub_val[key] || sub_val[key.to_sym]
                            end
                        end
                    rescue => e
                        # warn of potential issue here
                        @logger.warn "#{e.message}\nsubkey not found for trigger #{@id}: #{val_key}" if @logger
                        value = nil
                    end
                end

                # Symbols won't work as triggers as they can't be expressed in JSON
                value.is_a?(Symbol) ? value.to_s.freeze : value
            end


            # Helper Methods
            def equal(left, right)
                left == right
            end

            def not_equal(left, right)
                left != right
            end

            def greater_than(left, right)
                left > right
            end

            def greater_than_or_equal(left, right)
                left >= right
            end

            def less_than(left, right)
                left < right
            end

            def less_than_or_equal(left, right)
                left <= right
            end

            def and(left, right)
                (!!left) && (!!right)
            end

            def or(left, right)
                (!!left) || (!!right)
            end

            def exclusive_or(left, right)
                (!!left) ^ (!!right)
            end


            # Time methods
            def at(schedule_id, value)
                @schedules[schedule_id] = @scheduler.at(value[:value]) do
                    timeout = :"#{schedule_id}_timeout"

                    @values[schedule_id] = true
                    check_conditions if @enabled

                    # 1min window of value high for times
                    @schedules[timeout] = @scheduler.in(59000) do
                        @schedules.delete(timeout)
                        @values[schedule_id] = false
                        check_conditions if @enabled
                    end
                end
            end

            def cron(schedule_id, value)
                @schedules[schedule_id] = @scheduler.cron(value[:value]) do
                    timeout = :"#{schedule_id}_timeout"

                    @values[schedule_id] = true
                    check_conditions if @enabled

                    # 1min window of value high for times
                    @schedules[timeout] = @scheduler.in(59000) do
                        @schedules.delete(timeout)
                        @values[schedule_id] = false
                        check_conditions if @enabled
                    end
                end
            end
        end
    end
end
