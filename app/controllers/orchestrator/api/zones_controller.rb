# frozen_string_literal: true

module Orchestrator
    module Api
        class ZonesController < ApiController
            before_action :check_admin, except: [:index, :show]
            before_action :find_zone, only: [:show, :update, :destroy]


            @@elastic ||= Elastic.new(Zone)
            ZONE_DATA = {only: [:id, :name, :tags, :created_at]}


            def index
                query = @@elastic.query(params)
                query.sort = NAME_SORT_ASC

                if params.has_key? :tags
                    query.and_filter({
                        "doc.tags" => params.permit(:tags)[:tags].split(/\s+/)
                    })
                else
                    query.search_field 'doc.name'
                end

                results = @@elastic.search(query) do |zone|
                    zone.as_json(ZONE_DATA)
                end
                render json: results
            end

            def show
                if params.has_key? :data
                    key = params.permit(:data)[:data]
                    info = @zone.settings[key]
                    if info.is_a?(Array) || info.is_a?(Hash)
                        render json: info
                    else
                        head :not_found
                    end
                else
                    user = current_user
                    return head :forbidden unless user && (user.support || user.sys_admin)

                    if params.has_key? :complete
                        render json: @zone.as_json(methods: [:trigger_data])
                    else
                        render json: @zone
                    end
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
                # destroy will update CS and zone caches
                @zone.destroy
                head :ok
            end


            protected


            ZONE_PARAMS = [
                :name, :description, :tags,
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
