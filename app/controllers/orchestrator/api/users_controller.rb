# frozen_string_literal: true

module Orchestrator
    module Api
        class UsersController < ApiController
            before_action :check_authorization, only: [:update]
            before_action :check_admin, only: [:index, :destroy, :create]


            before_action :doorkeeper_authorize!


            # deal with live reload   filter
            @@elastic ||= Elastic.new(User)

             # Admins can see a little more of the users data
            ADMIN_DATA = User::PUBLIC_DATA.dup
            ADMIN_DATA[:only] += [:support, :sys_admin, :email, :phone]


            def index
                query = @@elastic.query(params)
                query.not({'doc.deleted' => [true]})
                authority_id = params.permit(:authority_id)[:authority_id]
                query.filter({'doc.authority_id' => [authority_id]}) if authority_id
                results = @@elastic.search(query) do |user|
                    user.as_json(ADMIN_DATA)
                end
                render json: results
            end

            def show
                user = User.find(id)

                # We only want to provide limited 'public' information
                if current_user.sys_admin
                    render json: user.as_json(ADMIN_DATA)
                else
                    render json: user.as_json(User::PUBLIC_DATA)
                end
            end

            def current
                render json: current_user
            end

            def create
                user = User.new(safe_params)
                user.authority = current_authority
                save_and_respond user
            end


            ##
            # Requests requiring authorization have already loaded the model
            def update
                @user.assign_attributes(safe_params)
                @user.save
                render json: @user
            end

            # Make this available when there is a clean up option
            def destroy
                @user = User.find(id)

                if defined?(::UserCleanup)
                    @user.destroy
                    head :ok
                else
                    ::Auth::Authentication.for_user(@user.id).each do |auth|
                        auth.destroy
                    end
                    @user.destroy
                end
            end


            protected


            def safe_params
                if current_user.sys_admin
                    params.require(:user).permit(
                        :name, :first_name, :last_name, :country, :building, :email, :phone, :nickname,
                        :card_number, :login_name, :staff_id, :sys_admin, :support, :password, :password_confirmation
                    ).to_h
                else
                    params.require(:user).permit(
                        :name, :first_name, :last_name, :country, :building, :email, :phone, :nickname
                    ).to_h
                end
            end

            def check_authorization
                # Find will raise a 404 (not found) if there is an error
                @user = User.find(id)
                user = current_user

                # Does the current user have permission to perform the current action
                head(:forbidden) unless @user.id == user.id || user.sys_admin
            end
        end
    end
end
