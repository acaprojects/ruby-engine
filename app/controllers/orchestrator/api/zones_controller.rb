# frozen_string_literal: true

module Orchestrator
    module Api
        class ZonesController < ApiController
            before_action :check_admin, except: [:index, :show]
            before_action :check_support, only: [:index, :show]
            before_action :find_zone, only: [:show, :update, :destroy]


            @@elastic ||= Elastic.new(Zone)


            def index
                query = @@elastic.query(params)
                query.sort = NAME_SORT_ASC
                query.search_field 'doc.name'

                render json: @@elastic.search(query)
            end

            def show
                if params.has_key? :complete
                    render json: @zone.as_json(methods: [:trigger_data])
                else
                    render json: @zone
                end
            end

            def update
                @zone.assign_attributes(safe_params)
                save_and_respond @zone
            end

            def create
                zone = Zone.new(safe_params)
                save_and_respond zone
            end

            def destroy
                # delete will update CS and zone caches
                @zone.delete
                head :ok
            end


            protected


            ZONE_PARAMS = [
                :name, :description,
                {triggers: []}
            ]
            def safe_params
                settings = params[:settings]
                args = params.permit(ZONE_PARAMS).to_h
                args[:settings] = settings.to_unsafe_hash if settings
                args
            end

            def find_zone
                # Find will raise a 404 (not found) if there is an error
                @zone = Zone.find(id)
            end
        end
    end
end
