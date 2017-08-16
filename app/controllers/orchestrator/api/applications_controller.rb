# frozen_string_literal: true

module Orchestrator
    module Api
        class ApplicationsController < ApiController
            before_action :check_admin
            before_action :find_app, only: [:show, :update, :destroy]


            @@elastic ||= Elastic.new(::Doorkeeper::Application, use_couch_type: true)


            def index
                query = @@elastic.query(params)

                owner_id = params.permit(:owner)[:owner]
                if owner_id
                    query.filter({
                        'doc.owner_id' => [owner_id]
                    })
                end

                query.sort = NAME_SORT_ASC
                query.search_field 'doc.name'

                render json: @@elastic.search(query)
            end

            def show
                render json: @app
            end

            def update
                @app.assign_attributes(safe_params)
                save_and_respond @app
            end

            def create
                app = ::Doorkeeper::Application.new(safe_params)
                save_and_respond app
            end

            def destroy
                @app.destroy
                head :ok
            end


            protected


            APP_PARAMS = [
                :name, :scopes, :redirect_uri, :skip_authorization
            ]
            def safe_params
                params.permit(APP_PARAMS).to_h
            end

            def find_app
                # Find will raise a 404 (not found) if there is an error
                @app = ::Doorkeeper::Application.find(id)
            end
        end
    end
end
