# frozen_string_literal: true

module Orchestrator
    module Api
        class TriggersController < ApiController
            # state, funcs, count and types are available to authenticated users
            before_action :check_admin,   only: [:create, :update, :destroy]
            before_action :check_support, only: [:index, :show]
            before_action :find_trigger,  only: [:show, :update, :destroy]


            @@elastic ||= Elastic.new(Trigger)


            def index
                query = @@elastic.query(params)
                query.sort = NAME_SORT_ASC
                render json: @@elastic.search(query)
            end

            def show
                render json: @trig
            end

            def update
                @trig.assign_attributes(safe_params)
                save_and_respond(@trig)
            end

            def create
                trig = Trigger.new(safe_params)
                save_and_respond trig
            end

            def destroy
                @trig.delete # expires the cache in after callback
                head :ok
            end


            protected


            # Better performance as don't need to create the object each time
            TRIGGER_PARAMS = [
                :name, :description, :debounce_period
            ]
            # We need to support an arbitrary settings hash so have to
            # work around safe params as per 
            # http://guides.rubyonrails.org/action_controller_overview.html#outside-the-scope-of-strong-parameters
            def safe_params
                conditions = params[:conditions]
                actions = params[:actions]

                {
                    conditions: conditions.is_a?(::Array) ? conditions : nil,
                    actions: actions.is_a?(::Array) ? actions : []
                }.merge(params.permit(TRIGGER_PARAMS))
            end

            def find_trigger
                # Find will raise a 404 (not found) if there is an error
                @trig = Trigger.find(id)
            end
        end
    end
end
