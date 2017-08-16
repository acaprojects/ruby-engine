# frozen_string_literal: true

module Orchestrator
    module Api
        class DomainsController < ApiController
            before_action :check_admin
            before_action :find_authority, only: [:show, :update, :destroy]


            @@elastic ||= Elastic.new(::Authority)


            def index
                query = @@elastic.query(params)
                query.sort = NAME_SORT_ASC
                query.search_field 'doc.name'

                render json: @@elastic.search(query)
            end

            def show
                render json: @authority
            end

            def update
                @authority.assign_attributes(safe_params)
                save_and_respond @authority
            end

            def create
                auth = ::Authority.new(safe_params)
                save_and_respond auth
            end

            def destroy
                @authority.destroy
                head :ok
            end


            protected


            AUTHORITY_PARAMS = [
                :name, :dom, :description, :login_url, :logout_url
            ]
            def safe_params
                internals = params[:internals]
                config = params[:config]

                args = params.permit(AUTHORITY_PARAMS).to_h
                args[:internals] = internals.to_unsafe_hash if internals
                args[:config] = config.to_unsafe_hash if config
                args
            end

            def find_authority
                # Find will raise a 404 (not found) if there is an error
                @authority = ::Authority.find(id)
            end
        end
    end
end
