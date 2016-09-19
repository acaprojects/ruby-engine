# frozen_string_literal: true

module Orchestrator
    module Api
        class DependenciesController < ApiController
            before_action :check_admin, except: [:index, :show]
            before_action :check_support, only: [:index, :show]
            before_action :find_dependency, only: [:show, :update, :destroy, :reload]


            @@elastic ||= Elastic.new(Dependency)


            def index
                role = params.permit(:role)[:role]
                query = @@elastic.query(params)

                if role && Dependency::ROLES.include?(role.to_sym)
                    query.filter({
                        'doc.role' => [role]
                    })
                end

                query.sort = NAME_SORT_ASC

                render json: @@elastic.search(query)
            end

            def show
                render json: @dep
            end

            def update
                args = safe_params
                args.delete(:role)
                args.delete(:class_name)

                # Must destroy and re-add to change class or module type
                @dep.assign_attributes(args)
                save_and_respond @dep
            end

            def create
                dep = Dependency.new(safe_params)
                save_and_respond dep
            end

            def destroy
                @dep.delete
                head :ok
            end


            ##
            # Additional Functions:
            ##

            def reload
                depman = ::Orchestrator::DependencyManager.instance

                begin
                    # Note:: Coroutine waiting for dependency load
                    co depman.load(@dep, :force)
                    content = nil
                    status = :ok

                    begin
                        updated = 0

                        @dep.modules.each do |mod|
                            manager = mod.manager
                            if manager
                                updated += 1
                                manager.reloaded(mod)
                            end
                        end

                        content = {
                            message: updated == 1 ? "#{updated} module updated" : "#{updated} modules updated"
                        }.to_json
                    rescue => e
                        # Let user know about any post reload issues
                        message = "Warning! Reloaded successfully however some modules were not informed. It is safe to reload again.\nError was: #{e.message}"
                        status = :internal_server_error
                        content = {
                            message: message
                        }.to_json
                    end

                    render json: content, status: status
                rescue Exception => e
                    msg = String.new(e.message)
                    msg << "\n#{e.backtrace.join("\n")}" if e.respond_to?(:backtrace) && e.backtrace
                    render plain: msg, status: :internal_server_error
                end
            end


            protected


            DEP_PARAMS = [
                :name, :description, :role,
                :class_name, :module_name,
                :default
            ]
            def safe_params
                settings = params[:settings]
                {
                    settings: settings.is_a?(::Hash) ? settings : {}
                }.merge(params.permit(DEP_PARAMS))
            end

            def find_dependency
                # Find will raise a 404 (not found) if there is an error
                @dep = Dependency.find(id)
            end
        end
    end
end
