# frozen_string_literal: true

module Orchestrator; end

module Orchestrator::StateBinder
    module Methods
        Binding = Struct.new :mod, :status, :handler

        # Subscribe to updates to a modules status and bind to a system method
        # or a handler block.
        def bind(mod, status, to: nil, &handler)
            handler = proc { |val| send to, val } unless to.nil?
            state_bindings << Binding.new(mod, status, handler)
        end

        def state_bindings
            @state_bindings ||= []
        end

        def clear_state_bindings
            @state_bindings = nil
        end
    end

    module Hooks
        def on_update
            super
            @state_subscriptions&.each { |ref| unsubscribe ref }

            bindings = self.class.state_bindings

            @state_subscriptions = bindings.reduce([]) do |refs, b|
                refs << system.subscribe(b.mod, b.status) do |notify|
                    instance_exec(notify.value, notify.old_value, &b.handler)
                end
            end
        end
    end

    module_function

    def included(base)
        base.extend Methods
        base.prepend Hooks
        base.clear_state_bindings
    end
end
