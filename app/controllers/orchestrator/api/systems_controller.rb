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

            def show
                if params.has_key? :complete
                    render json: @cs.as_json({
                        methods: [:module_data, :zone_data]
                    })
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
                mod = ::Orchestrator::Module.find module_id

                if @cs.modules.include? module_id
                    remove = true

                    @cs.modules.delete(module_id)
                    @cs.save!

                    ControlSystem.using_module(module_id).each do |cs|
                        if cs.id != @cs.id
                            remove = false
                            break
                        end
                    end

                    mod.delete if remove
                end
                head :ok
            end

            def create
                cs = ControlSystem.new(safe_params)
                save_and_respond cs
            end

            def destroy
                @cs.delete # expires the cache in after callback
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
                end

                # TODO:: This needs to be done on the remote as well
                # Clear the system cache once the modules are loaded
                # This ensures the cache is accurate
                control.thread.finally(*loaded).then do
                    # Might as well trigger update behaviour.
                    # Ensures logic modules that interact with other logic modules
                    # are accurately informed
                    @cs.expire_cache   # :no_update
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

            def exec
                # Run a function in a system module (async request)
                params.require(:module)
                params.require(:method)
                sys = System.get(id)
                if sys
                    para = params.permit(:module, :index, :method, {args: []}).tap do |whitelist|
                        whitelist[:args] = params[:args] || []
                    end
                    index = para[:index]
                    mod = sys.get(para[:module].to_sym, index.nil? ? 1 : index.to_i)
                    if mod
                        user = current_user

                        # Execute request on appropriate thread
                        defer = reactor.defer
                        mod.thread.schedule do
                            perform_exec(defer, mod, para, user)
                        end
                        result = defer.value

                        begin
                            # Placed into an array so it is valid JSON
                            # Might return a string or number
                            render json: [result]
                        rescue
                            # respond with nil if object cannot be converted to JSON
                            head :ok
                        end
                    else
                        head :not_found
                    end
                else
                    head :not_found
                end
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
                args = {
                    modules: [],
                    zones: [],
                    settings: settings.is_a?(::Hash) ? settings : {}
                }.merge!(params.permit(CS_PARAMS))
                args[:installed_ui_devices] = args[:installed_ui_devices].to_i if args.has_key? :installed_ui_devices
                args[:capacity] = args[:capacity].to_i if args.has_key? :capacity
                args
            end

            def find_system
                # Find will raise a 404 (not found) if there is an error
                sys = ::Orchestrator::ControlSystem.bucket.get("sysname-#{id.downcase}", {quiet: true}) || id
                @cs = ControlSystem.find(sys)
            end

            # Called on the module thread
            def perform_exec(defer, mod, para, user)
                req = Core::RequestProxy.new(mod.thread, mod, user)
                args = para[:args] || []
                result = req.method_missing(para[:method].to_sym, *args)

                # timeout in case message is queued
                timeout = mod.thread.scheduler.in(5000) do
                    defer.resolve('Wait time exceeded. Command may have been queued.')
                end

                result.finally do
                    timeout.cancel # if we have our answer
                    defer.resolve(result)
                end
            end
        end
    end
end
