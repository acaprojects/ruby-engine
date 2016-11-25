# frozen_string_literal: true

require 'set'

module Orchestrator
    module Api
        class ModulesController < ApiController
            before_action :check_admin, except: [:index, :state, :show]
            before_action :check_support, only: [:index, :state, :show]
            before_action :find_module,   only: [:show, :update, :destroy]


            @@elastic ||= Elastic.new(::Orchestrator::Module)

            # Constant for performance
            MOD_INCLUDE = {
                include: {
                    # Most human readable module data is contained in dependency
                    dependency: {only: [:name, :description, :module_name, :settings]},

                    # include control system on logic modules so it is possible
                    # to display the inherited settings
                    control_system: {
                        only: [:name, :settings],
                        methods: [:zone_data]
                    }
                }
            }


            def index
                filters = params.permit(:system_id, :dependency_id, :connected, :no_logic, :running, :as_of)

                # if a system id is present we query the database directly
                if filters[:system_id]
                    cs = ControlSystem.find(filters[:system_id])

                    results = Array(::Orchestrator::Module.find_by_id(cs.modules));
                    render json: {
                        total: results.length,
                        results: results
                    }
                else # we use elastic search
                    query = @@elastic.query(params)
                    filter = {}

                    if filters[:dependency_id]
                        filter['doc.dependency_id'] = [filters[:dependency_id]]
                    end

                    if filters[:connected]
                        connected = filters[:connected] == 'true'
                        filter['doc.ignore_connected'] = [false]
                        filter['doc.connected'] = [connected]
                    end

                    if filters[:running]
                        running = filters[:running] == 'true'
                        filter['doc.running'] = [running]
                    end

                    if filters.has_key? :no_logic
                        filter['doc.role'] = [1, 2]
                    end

                    if filters.has_key? :as_of
                        query.raw_filter({
                            range: {
                                'doc.updated_at' => {
                                    lte: filters[:as_of].to_i
                                }
                            }
                        })
                    end

                    query.filter(filter) unless filter.empty?
                    query.has_parent :dep

                    results = @@elastic.search(query)
                    render json: results.as_json(MOD_INCLUDE)
                end
            end

            def show
                render json: @mod.as_json(MOD_INCLUDE)
            end

            def update
                para = safe_params
                @mod.assign_attributes(para)
                was_running = @mod.running

                save_and_respond(@mod, include: {
                    dependency: {
                        only: [:name, :module_name]
                    }
                }) do
                    # Update the running module
                    promise = control.update(id)
                    if was_running
                        promise.finally do
                            control.start(id)
                        end
                    end
                end
            end

            def create
                mod = ::Orchestrator::Module.new(safe_params)
                save_and_respond mod
            end

            def destroy
                @mod.delete
                head :ok
            end


            ##
            # Additional Functions:
            ##

            def start
                # It is possible that module class load can fail
                result = co control.start(id)
                if result
                    head :ok
                else
                    render plain: 'module failed to start', status: :internal_server_error
                end
            end

            def stop
                co control.stop(id)
                head :ok
            end

            # Returns the value of the requested status variable
            # Or dumps the complete status state of the module
            def state
                lookup_module do |mod|
                    para = params.permit(:lookup)
                    if para.has_key?(:lookup)
                        render json: mod.status[para[:lookup].to_sym]
                    else
                        render json: mod.status.marshal_dump
                    end
                end
            end

            # Dumps internal state out of the logger at debug level
            # and returns the internal state
            def internal_state
                lookup_module do |mod|
                    defer = reactor.defer
                    mod.thread.next_tick do
                        begin
                            defer.resolve(mod.instance.__STATS__)
                        rescue => err
                            defer.reject(err)
                        end
                    end
                    render json: defer.promise.value
                end
            end


            protected


            MOD_PARAMS = [
                :dependency_id, :control_system_id, :edge_id,
                :ip, :tls, :udp, :port, :makebreak, :uri,
                :custom_name, :notes, :ignore_connected
            ]
            def safe_params
                settings = params[:settings]
                args = params.permit(MOD_PARAMS).to_h
                args[:settings] = settings.to_unsafe_hash if settings
                args
            end

            def lookup_module
                mod = control.loaded? id
                if mod
                    yield mod
                else
                    head :not_found
                end
            end

            def find_module
                # Find will raise a 404 (not found) if there is an error
                @mod = ::Orchestrator::Module.find(id)
            end

            def expire_system_cache(mod_id)
                ControlSystem.using_module(mod_id).each do |cs|
                    cs.expire_cache :no_update
                end
            end
        end
    end
end
