# frozen_string_literal: true

module Orchestrator
    module Core
        module Mixin
            # Returns the module id as defined in the database.
            #
            # @return [Symbol] the id of the module instance
            def id
                @__config__.settings.id.to_sym
            end

            # Returns a wrapper around a shared instance of ::UV::Scheduler
            #
            # @return [::Orchestrator::Core::ScheduleProxy]
            def schedule
                @__config__.get_scheduler
            end

            # Returns a proxy to that system
            #
            # @param id [String|Symbol] the id of the system being accessed
            # @return [::Orchestrator::Core::SystemProxy] Returns a system proxy
            def systems(id)
                @__config__.get_system(id)
            end

            # Returns the system id for a system based on its name
            #
            # @param id [String] the name of the system to lookup
            # @return [::Libuv::Q::Promise] Returns a single promise
            def lookup_system(name)
                ::Orchestrator::ControlSystem.bucket.get("sysname-#{name.downcase}", quiet: true)
            end

            # Performs a long running task on a thread pool in parallel.
            #
            # @param callback [Proc] the work to be processed on the thread pool
            # @return [::Libuv::Q::Promise] Returns a single promise
            def task
                @__config__.thread.work { yield }
            end

            # Schedules code to run after the current flow of execution is complete
            # Similar to a task, except it will run on the same thread
            def next_tick
                # We use scheduler as this maintains the current user context
                @__config__.get_scheduler.in(0) { yield }
            end

            # Executes code in a fiber, starting that fiber immediately.
            # Once execution completes or the system waits for IO, it'll pass back execution where it left off
            def fiber_exec
                # Current user is maintained in fiber exec
                @__config__.thread.exec do
                    begin
                        yield
                    rescue => e
                        @__config__.logger.print_error e, 'in fiber exec'
                    end
                end
            end

            # Thread safe status access
            def [](name)
                @__config__.status[name.to_sym]
            end

            # thread safe status settings
            def []=(status, value)
                @__config__.trak(status.to_sym, value)
            end

            # force a status update to be sent
            def signal_status(name)
                @__config__.signal_status name.to_sym
            end

            # thread safe status subscription
            def subscribe(status, callback = nil, &block)
                callback ||= block
                raise 'callback required' unless callback.respond_to? :call

                cb = proc { |val|
                    begin
                        callback.call(val)
                    rescue => e
                        logger.print_error(e, 'in subscription callback')
                    end
                }

                thread = @__config__.thread
                if thread.reactor_thread?
                    @__config__.subscribe(status, cb)
                else
                    defer = thread.defer
                    thread.schedule do
                        defer.resolve(@__config__.subscribe(status, cb))
                    end
                    defer.promise.value
                end
            end

            # thread safe unsubscribe
            def unsubscribe(sub)
                @__config__.thread.schedule do
                    @__config__.unsubscribe(sub)
                end
            end

            def logger
                @__config__.logger
            end

            def setting(name, merge = nil)
                if block_given?
                    @__config__.setting(name, Proc.new)
                else
                    @__config__.setting(name, merge)
                end
            end

            # Similar to how you would extract settings. Except it
            # goes deep into any hashes and decrypts any encrypted keys
            # it finds.
            def decrypt(name)
                @__config__.decrypt(name)
            end

            def thread
                @__config__.thread
            end

            # Updates a setting that will effect the local module only
            #
            # @param name [String|Symbol] the setting name
            # @param value [String|Symbol|Numeric|Array|Hash] the setting value
            # @return [::Libuv::Q::Promise] Promise that will resolve once the setting is persisted
            def define_setting(name, value)
                @__config__.define_setting(name.to_sym, value)
            end

            def wake_device(mac, ip = nil)
                @__config__.thread.schedule do
                    @__config__.thread.wake_device(mac, ip)
                end
            end

            def current_user
                @__config__.current_user
            end

            # Indicates if a code reload is triggering the update
            def code_update
                @__config__.code_update
            end

            # Outputs any statistics collected on the module
            def __STATS__
                stats = {}
                if @__config__.respond_to? :processor
                    queue = @__config__.processor.queue
                    stats[:queue_size] = queue.length
                    stats[:queue_waiting] = !queue.waiting.nil?
                    stats[:queue_state] = queue.state

                    processor = @__config__.processor
                    stats[:buffered] = processor.buffer_size
                    stats[:last_send] = processor.last_sent_at
                    stats[:last_receive] = processor.last_receive_at
                    stats[:timeout] = processor.timeout if processor.timeout
                    stats[:transport] = processor.transport&.stats if processor.transport
                end

                stats[:time_now] = Time.now.to_i
                stats[:schedules] = schedule.schedules.to_a

                logger.debug stats.inspect
                stats
            end
        end
    end
end
