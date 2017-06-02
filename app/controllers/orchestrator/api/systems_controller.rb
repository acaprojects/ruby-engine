# frozen_string_literal: true

module Orchestrator
    module Api
        class SystemsController < ApiController
            # state, funcs, count and types are available to authenticated users
            before_action :check_admin,   only: [:create, :update, :destroy, :remove, :start, :stop]
            before_action :check_support, only: [:index, :exec]
            before_action :find_system,   only: [:show, :update, :destroy, :remove, :start, :stop]


            @@elastic ||= Elastic.new(ControlSystem)


            def index
                query = @@elastic.query(params)
                query.sort = NAME_SORT_ASC

                # Filter systems via zone_id
                if params.has_key? :zone_id
                    zone_id = params.permit(:zone_id)[:zone_id]
                    query.filter({
                        'doc.zones' => [zone_id]
                    })
                end

                # filter via module_id
                if params.has_key? :module_id
                    module_id = params.permit(:module_id)[:module_id]
                    query.filter({
                        'doc.modules' => [module_id]
                    })
                end

                query.search_field 'doc.name'
                render json: @@elastic.search(query)
            end

            SYS_INCLUDE = {
                include: {edge: {only: [:name, :description]}},
                methods: [:module_data, :zone_data]
            }
            def show
                if params.has_key? :complete
                    render json: @cs.as_json(SYS_INCLUDE)
                else
                    render json: @cs
                end
            end

            def update
                @cs.assign_attributes(safe_params)
                save_and_respond(@cs)
            end

            # Removes the module from the system and deletes it if not used elsewhere
            def remove
                module_id = params.permit(:module_id)[:module_id]

                if @cs.modules.include? module_id
                    remove = true

                    mods = @cs.modules.dup
                    mods.delete(module_id)
                    @cs.modules = mods
                    @cs.save! with_cas: true

                    ControlSystem.using_module(module_id).each do |cs|
                        if cs.id != @cs.id
                            remove = false
                            break
                        end
                    end

                    if remove
                        begin
                            mod = ::Orchestrator::Module.find module_id
                            mod.destroy
                        rescue ::Libcouchbase::Error::KeyNotFound => e
                        end
                    end
                end
                head :ok
            end

            def create
                cs = ControlSystem.new(safe_params)
                save_and_respond cs
            end

            def destroy
                sys_id = @cs.id

                # Stop all modules in the system
                wait = @cs.cleanup_modules

                co reactor.finally(*wait).then {
                    @cs.destroy
                }

                # Clear the cache
                co control.expire_cache(sys_id)

                head :ok
            end


            ##
            # Additional Functions:
            ##

            def start
                loaded = []

                # Start all modules in the system
                @cs.modules.each do |mod_id|
                    promise = control.start mod_id
                    loaded << promise
                end

                # This needs to be done on the remote as well
                # Clear the system cache once the modules are loaded
                # This ensures the cache is accurate
                co control.reactor.finally(*loaded).then do
                    # Might as well trigger update behaviour.
                    # Ensures logic modules that interact with other logic modules
                    # are accurately informed
                    control.expire_cache(@cs)
                end

                head :ok
            end

            def stop
                # Stop all modules in the system (shared or not)
                @cs.modules.each do |mod_id|
                    control.stop mod_id
                end
                head :ok
            end

            EXEC_PARAMS = [:module, :index, :method, {
                args: []
            }]
            def exec
                # Run a function in a system module (async request)
                params.require(:module)
                params.require(:method)
                para = params.permit(EXEC_PARAMS).tap do |whitelist|
                    whitelist[:args] = Array(params[:args])
                end

                reactor = ::Libuv.reactor

                defer = reactor.defer
                sys  = ::Orchestrator::Core::SystemProxy.new(reactor, id)
                mod = sys.get(para[:module], para[:index] || 1)

                result = mod.method_missing(para[:method], *para[:args])

                # timeout in case message is queued
                timeout = reactor.scheduler.in(5000) do
                    defer.resolve('Wait time exceeded. Command may have been queued.')
                end

                result.finally do
                    timeout.cancel # if we have our answer
                    defer.resolve(result)
                end

                value = defer.promise.value

                begin
                    # Placed into an array so primitives values are returned as valid JSON
                    render json: [prepare_json(value)]
                rescue Exception => e
                    # respond with nil if object cannot be converted to JSON
                    logger.info "failed to convert object #{value} to JSON"
                    render json: ['response could not be rendered in JSON']
                end
            rescue => e
                render json: ["#{e.message}\n#{e.backtrace.join("\n")}"], status: :internal_server_error
            end

            def state
                # Status defined as a system module
                params.require(:module)
                sys = System.get(id)
                if sys
                    para = params.permit(:module, :index, :lookup)
                    index = para[:index]
                    mod = sys.get(para[:module].to_sym, index.nil? ? 1 : index.to_i)
                    if mod
                        if para.has_key?(:lookup)
                            render json: mod.status[para[:lookup].to_sym]
                        else
                            mod.thread.next_tick do
                                mod.instance.__STATS__
                            end
                            render json: mod.status.marshal_dump
                        end
                    else
                        head :not_found
                    end
                else
                    head :not_found
                end
            end

            # returns a list of functions available to call
            Ignore = Set.new([
                Object, Kernel, BasicObject,
                Constants, Transcoder,
                Core::Mixin, Logic::Mixin, Device::Mixin, Service::Mixin
            ])
            def funcs
                params.require(:module)
                sys = System.get(id)
                if sys
                    para = params.permit(:module, :index)
                    index = para[:index]
                    index = index.nil? ? 1 : index.to_i;

                    mod = sys.get(para[:module].to_sym, index)
                    if mod
                        klass = mod.klass

                        # Find all the public methods available for calling
                        # Including those methods from ancestor classes
                        funcs = []
                        klass.ancestors.each do |methods|
                            break if Ignore.include? methods 
                            funcs += methods.public_instance_methods(false)
                        end
                        # Remove protected methods
                        pub = funcs.select { |func| !Core::PROTECTED[func] }

                        # Provide details on the methods
                        resp = {}
                        pub.each do |pfunc|
                            meth = klass.instance_method(pfunc.to_sym)
                            resp[pfunc] = {
                                arity: meth.arity,
                                params: meth.parameters
                            }
                        end

                        render json: resp
                    else
                        head :not_found
                    end
                else
                    head :not_found
                end
            end

            # return the count of a module type in a system
            def count
                params.require(:module)
                sys = System.get(id)
                if sys
                    mod = params.permit(:module)[:module]
                    render json: {count: sys.count(mod)}
                else
                    head :not_found
                end
            end

            # returns a hash of a module types in a system with
            # the count of each of those types
            def types
                sys = System.get(id)
                
                if sys
                    result = {}
                    mods = sys.modules
                    mods.delete(:__Triggers__)
                    mods.each do |mod|
                        result[mod] = sys.count(mod)
                    end

                    render json: result
                else
                    head :not_found
                end
            end


            protected


            # Better performance as don't need to create the object each time
            CS_PARAMS = [
                :name, :edge_id, :description, :support_url, :installed_ui_devices,
                :capacity, :email, :bookable, :features,
                {
                    zones: [],
                    modules: []
                }
            ]
            # We need to support an arbitrary settings hash so have to
            # work around safe params as per 
            # http://guides.rubyonrails.org/action_controller_overview.html#outside-the-scope-of-strong-parameters
            def safe_params
                settings = params[:settings]
                args = params.permit(CS_PARAMS).to_h
                args[:settings] = settings.to_unsafe_hash if settings
                args[:installed_ui_devices] = args[:installed_ui_devices].to_i if args.has_key? :installed_ui_devices
                args[:capacity] = args[:capacity].to_i if args.has_key? :capacity
                args
            end

            def find_system
                # Find will raise a 404 (not found) if there is an error
                sys_id = id
                @cs = ControlSystem.find_by_id(sys_id) || ControlSystem.find(ControlSystem.bucket.get("sysname-#{id.downcase}", quiet: true))
            end
        end
    end
end
