# frozen_string_literal: true

module Orchestrator
    module Api
        class WebhooksController < ::ActionController::Base
            before_action :find_hook

            # Provide details of the webhooks operation
            def show
                exec = params.permit(:exec)[:exec]
                return notify if exec == 'true'
                render json: @trigger
            end

            # Triggers the webhook
            # 3 types of webhook: (all execute trigger actions, if any)
            #  * Ignore payload
            #  * Perform payload before actions
            #  * Perform payload after actions
            def notify
                # Update count without reloading the trigger
                sys  = ::Orchestrator::Core::SystemProxy.new(::Libuv.reactor, @trigger.control_system_id)
                trig = sys[:__Triggers__]

                case @trigger.conditions[0][1].to_sym
                when :payload_only
                    exec_payload(sys)
                    User.bucket.subdoc(@trigger.id) do |doc|
                        doc.counter('trigger_count', 1)
                    end
                    trig["#{@trigger.binding}_count"] += 1

                when :execute_before
                    exec_payload(sys)
                    trig.webhook(@trigger.id)

                when :execute_after
                    trig.webhook(@trigger.id)
                    exec_payload(sys)

                else # ignore payload
                    trig.webhook(@trigger.id)
                end

                head :accepted
            end


            protected


            def exec_payload(sys)
                args = safe_params
                mod = sys.get(args[:module], args[:index] || 1)
                mod.method_missing(args[:method], *args[:args])
            rescue ActionController::ParameterMissing
                # payload not included in request
            end

            WEBHOOK_PARAMS = [:metadata, :module, :index, :method, {
                args: []
            }]
            def safe_params
                params.require(:module)
                params.require(:method)
                params.permit(WEBHOOK_PARAMS).tap do |whitelist|
                    whitelist[:args] = Array(params[:args])
                end
            end

            def find_hook
                params.require(:id)
                params.require(:secret)
                args = params.permit(:id, :secret)

                # Find will raise a 404 (not found) if there is an error
                @trigger = TriggerInstance.find(args[:id])
                unless @trigger.webhook_secret == args[:secret] && @trigger.conditions[0][0] == 'webhook'
                    head :not_found
                end
            end
        end
    end
end
