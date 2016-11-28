# frozen_string_literal: true

module Orchestrator
    module Api
        class SystemTriggersController < ApiController
            # state, funcs, count and types are available to authenticated users
            before_action :check_admin,   only: [:create, :update, :destroy]
            before_action :check_support, only: [:index, :show]
            before_action :find_instance, only: [:show, :update, :destroy]


            @@elastic ||= Elastic.new(TriggerInstance)


            SYS_INCLUDE = {
                include: {
                    # include control system on logic modules so it is possible
                    # to display the inherited settings
                    control_system: {
                        only: [:name, :id],
                    }
                }
            }
            QUERY_PARAMS = [:sys_id, :trigger_id, :as_of]
            def index
                query = @@elastic.query(params)
                safe_query = params.permit(QUERY_PARAMS)
                filter = {}

                # Filter by system ID
                if safe_query.has_key? :sys_id
                    filter['doc.control_system_id'] = [safe_query[:sys_id]]
                end

                # Filter by trigger ID
                if safe_query.has_key? :trigger_id
                    filter['doc.trigger_id'] = [safe_query[:trigger_id]]
                end

                # Filter by importance
                if params.has_key? :important
                    filter['doc.important'] = [true]
                end

                # Filter by triggered
                if params.has_key? :triggered
                    filter['doc.triggered'] = [true]
                end

                # That occured before a particular time
                if safe_query.has_key? :as_of
                    query.raw_filter({
                        range: {
                            'doc.updated_at' => {
                                lte: safe_query[:as_of].to_i
                            }
                        }
                    })
                end

                query.filter(filter)

                # Include parent documents in the search
                query.has_parent :trigger
                results = @@elastic.search(query)
                if safe_query.has_key? :trigger_id
                    render json: results.as_json(SYS_INCLUDE)
                else
                    render json: results
                end
            end

            def show
                respond_with @trig
            end

            def update
                @trig.assign_attributes(safe_update)
                save_and_respond(@trig)
            end

            def create
                trig = TriggerInstance.new(safe_create)
                trig.save
                render json: trig
            end

            def destroy
                @trig.delete # expires the cache in after callback
                head :ok
            end


            protected


            # Better performance as don't need to create the object each time
            CREATE_PARAMS = [
                :enabled, :important, :control_system_id, :trigger_id
            ]
            def safe_create
                params.permit(CREATE_PARAMS).to_h
            end
            
            UPDATE_PARAMS = [
                :enabled, :important
            ]
            def safe_update
                params.permit(UPDATE_PARAMS).to_h
            end

            def find_instance
                # Find will raise a 404 (not found) if there is an error
                @trig = TriggerInstance.find(id)
            end
        end
    end
end
