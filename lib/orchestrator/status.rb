# frozen_string_literal: true

module Orchestrator
    Subscription = Struct.new(:sys_name, :sys_id, :mod_name, :mod_id, :index, :status, :callback, :on_thread) do
        @@mutex = Mutex.new
        @@sub_id = 1

        def initialize(*args)
            super(*args)

            @@mutex.synchronize {
                @@sub_id += 1
                @sub_id = @@sub_id
            }

            @do_callback = proc { callback.call(self) }
        end

        def notify(update, force = false)
            if update != @value || force
                @value = update
                on_thread.schedule @do_callback
            end
        end

        attr_reader :value, :sub_id
    end

    class Status
        def initialize(thread, controller)
            @thread = thread
            @controller = controller

            @find_subscription = method(:find_subscription)

            # {:mod_id => {status => Subscriptions}}
            @subscriptions = {}
            # {:system_id => Subscriptions}
            @systems = {}
        end


        attr_reader :thread


        # Subscribes to updates from a system module
        # Modules do not have to exist and updates will be triggered as soon as they do exist
        def subscribe(status:, callback:, on_thread:, sys_name: nil, sys_id: nil, mod: nil, mod_name: nil, mod_id: nil, index: nil)
            # Build the subscription object (as loosely coupled as we can)
            sub = Subscription.new(as_sym(sys_name), as_sym(sys_id), as_sym(mod_name), as_sym(mod_id), index.to_i, as_sym(status), callback, on_thread)

            if sys_id
                @systems[sub.sys_id] ||= {}
                @systems[sub.sys_id][sub.sub_id] = sub
            end

            # Now if the module is added later we'll still receive updates
            # and also support direct module status bindings
            if mod_id
                @subscriptions[sub.mod_id] ||= {}
                @subscriptions[sub.mod_id][sub.status] ||= {}
                @subscriptions[sub.mod_id][sub.status][sub.sub_id] = sub

                # Check for existing status to send to subscriber
                value = mod.status[sub.status]
                sub.notify(value) unless value.nil?
            end

            # return the subscription
            sub
        end

        # Removes subscription callback from the lookup
        def unsubscribe(sub)
            if sub.is_a? ::Libuv::Q::Promise
                sub.then @find_subscription
            else
                find_subscription(sub)
            end
        end

        # Triggers an update to be sent to listening callbacks
        def update(mod_id, status, value, force = false)
            mod = @subscriptions[mod_id.to_sym]
            if mod
                subscribed = mod[status.to_sym]
                if subscribed
                    subscribed.each_value do |subscription|
                        begin
                            subscription.notify(value, force)
                        rescue => e
                            @controller.log_unhandled_exception(e)
                        end
                    end
                end
            end
        end

        # Used to maintain subscriptions where module is moved to another thread
        # or even another server.
        def move(mod_id, to_thread)
            # Also called from edge_control.load
            return if to_thread == @thread

            mod_id = mod_id.to_sym

            @thread.schedule do
                statuses = @subscriptions.delete(mod_id)

                if statuses
                    statuses.each_value do |subs|
                        # Remove the system references from this thread
                        subs.each_value do |sub|
                            @systems[sub.sys_id].delete(sub.sub_id) if sub.sys_id
                        end
                    end

                    # Transfer the subscriptions
                    to_thread.observer.transfer(mod_id, statuses)
                end
            end
        end

        def transfer(mod_id, statuses)
            @thread.schedule do
                @subscriptions[mod_id.to_sym] = statuses

                mod_man = @controller.loaded? mod_id

                # Rebuild the system level lookup on this thread
                statuses.each_value do |subs|
                    subs.each_value do |sub|
                        if sub.sys_id
                            @systems[sub.sys_id] ||= {}
                            @systems[sub.sys_id][sub.sub_id] = sub

                            # Update the status value
                            value = mod_man.status[sub.status]
                            sub.notify(value)
                        end
                    end
                end
            end
        end

        # The System class contacts each of the threads to let them know of an update
        def reloaded_system(sys_id, sys)
            subscriptions = @systems[sys_id.to_sym]
            if subscriptions
                subscriptions.each_value do |sub|
                    old_id = sub.mod_id

                    # re-index the subscription
                    mod = sys.get(sub.mod_name, sub.index - 1)
                    sub.mod_id = mod ? mod.settings.id.to_sym : nil

                    # Check for changes (order, removal, replacement)
                    if old_id != sub.mod_id
                        old_sub = @subscriptions[old_id]
                        old_sub[sub.status].delete(sub.sub_id) if old_sub

                        # Update to the new module
                        if mod
                            @subscriptions[sub.mod_id] ||= {}
                            @subscriptions[sub.mod_id][sub.status] ||= {}
                            @subscriptions[sub.mod_id][sub.status][sub.sub_id] = sub

                            # Check for existing status to send to subscriber
                            value = mod.status[sub.status]
                            sub.notify(value) unless value.nil?

                            # Transfer the subscription if on a different thread
                            if mod.thread != @thread
                                move(sub.mod_id.to_sym, mod.thread)
                            end
                        end

                        # Perform any required cleanup
                        if old_sub && old_sub[sub.status].empty?
                            old_sub.delete(sub.status)
                            if old_sub.empty?
                                @subscriptions.delete(old_id)
                            end
                        end
                    end
                end
            end
        end


        # NOTE:: Only to be called from subscription thread
        def exec_unsubscribe(sub)
            # Update the system lookup if a system was specified
            if sub.sys_id
                subscriptions = @systems[sub.sys_id]
                if subscriptions
                    subscriptions.delete(sub.sub_id)

                    if subscriptions.empty?
                        @systems.delete(sub.sys_id)
                    end
                end
            end

            # Update the module lookup
            statuses = @subscriptions[sub.mod_id]
            if statuses
                subscriptions = statuses[sub.status]
                if subscriptions
                    subscriptions.delete(sub.sub_id)

                    if subscriptions.empty?
                        statuses.delete(sub.status)

                        if statuses.empty?
                            @subscriptions.delete(sub.mod_id)
                        end
                    end
                end
            end
        end


        protected


        def as_sym(obj)
            obj.to_sym if obj
        end

        def find_subscription(sub)
            # Find module thread
            if sub.mod_id
                manager = @controller.loaded?(sub.mod_id)
                if manager
                    thread = manager.thread
                    thread.schedule do
                        thread.observer.exec_unsubscribe(sub)
                    end
                else
                    # Should be in our schedule
                    exec_unsubscribe(sub)
                end
            else
                exec_unsubscribe(sub)
            end
        end
    end
end

module Libuv
    class Reactor
        def observer
            @observer ||= ::Orchestrator::Status.new(@reactor, ::Orchestrator::Control.instance)
            @observer
        end
    end
end
