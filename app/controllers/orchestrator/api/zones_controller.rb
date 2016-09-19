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
                render json: @zone
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
                {groups: []}
            ]
            def safe_params
                settings = params[:settings]
                {
                    settings: settings.is_a?(::Hash) ? settings : {},
                    groups: []
                }.merge(params.permit(ZONE_PARAMS))
            end

            def find_zone
                # Find will raise a 404 (not found) if there is an error
                @zone = Zone.find(id)
            end
        end
    end
end
