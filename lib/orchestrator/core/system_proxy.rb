# frozen_string_literal: true

require 'set'

module Orchestrator
    module Core
        class SystemProxy
            def initialize(thread, sys_id, origin = nil, user = nil)
                @system = sys_id.to_sym
                @thread = thread
                @origin = origin    # This is the module that requested the proxy
                @user = user
            end

            # Checks if the system is available from this server?
            # You may have passed in a bad system ID
            def available?
                !system.nil?
            end

            # Alias for get
            def [](mod)
                get mod
            end

            # Returns the system database model
            #
            # @return [ControlSystem] the database model
            def config
                system.config
            end

            # Provides a proxy to a module for a safe way to communicate across threads
            #
            # @param module [String, Symbol] the name of the module in the system
            # @param index [Integer] the index of the desired module (starting at 1)
            # @return [::Orchestrator::Core::RequestsProxy] proxies requests to a single module
            def get(mod, index = 1)
                index -= 1  # Get the real index
                name = mod.to_sym

                RequestProxy.new(@thread, system.get(name, index), @user)
            end

            # Provides a proxy to a module for a safe way to communicate across threads
            #
            # @param module [String, Symbol] the name of the module in the system suffixed with the index. i.e. ModuleName_IndexNumber
            # @return [::Orchestrator::Core::RequestsProxy] proxies requests to a single module
            def get_implicit(mod_id)
                res = mod_id.to_s.split(/_(?=[^_]+$)/)
                mod = res[0].to_sym
                id = res.length > 1 ? res[-1].to_i : 1
                
                get(mod, id)
            end

            # Checks for the existence of a particular module
            #
            # @param module [String, Symbol] the name of the module in the system
            # @param index [Integer] the index of the desired module (starting at 1)
            # @return [true, false] does the module exist?
            def exists?(mod, index = 1)
                index -= 1  # Get the real index
                name = mod.to_sym

                !system.get(name, index).nil?
            end

            # Provides a proxy to multiple modules. A simple way to send commands to multiple devices
            #
            # @param module [String, Symbol] the name of the module in the system
            # @return [::Orchestrator::Core::RequestsProxy] proxies requests to multiple modules
            def all(mod)
                RequestsProxy.new(@thread, system.all(mod.to_sym), @user)
            end

            # Iterates over the modules in the system. Can also specify module types.
            # 
            # @param mod_name [String, Symbol] the optional names of modules to iterate over
            # @yield [Module Instance, Symbol, Integer] yields the modules with their name and index
            def each(*args)
                mods = args.empty? ? modules : args
                mods.each do |mod|
                    number = count(mod)
                    (1..number).each do |index|
                        yield(get(mod, index), mod, index)
                    end
                end
            end

            # Grabs the number of a particular device type
            #
            # @param module [String, Symbol] the name of the module in the system
            # @return [Integer] the number of modules with a shared name
            def count(mod)
                system.count(mod.to_sym)
            end

            # Returns a list of all the module names in the system
            #
            # @return [Array] a list of all the module names
            def modules
                system.modules
            end

            # Returns the system name as defined in the database
            #
            # @return [String] the name of the system 
            def name
                system.config.name
            end

            # Returns the system email as defined in the database
            #
            # @return [String] any email associated with the system
            def email
                system.config.email
            end

            # Returns the room capacity as defined in the database
            #
            # @return [Integer] the size, in people, of the room
            def capacity
                system.config.capacity
            end

            # Returns if the room is bookable as defined in the database
            #
            # @return [true, false] if the system is bookable
            def bookable
                system.config.bookable
            end

            # Returns the system id as defined in the database
            #
            # @return [Symbol] the id of the system
            def id
                @system
            end

            # Used to be notified when an update to a status value occurs
            #
            # @param module [String, Symbol] the name of the module in the system
            # @param index [Integer] the index of the module as there may be more than one
            # @param status [String, Symbol] the name of the status variable
            # @param callback [Proc] method, block, proc or lambda to be called when a change occurs
            # @return [Object] a reference to the subscription for un-subscribing
            def subscribe(mod_name, index, status = nil, callback = nil, &block)
                # Allow index to be optional
                if not index.is_a?(Integer)
                    callback = status || block
                    status = index.to_sym
                    index = 1
                else
                    status = status.to_sym
                    callback ||= block
                end
                mod_name = mod_name.to_sym

                raise 'callback required' unless callback.respond_to? :call

                # We need to get the system to schedule threads
                sys = system
                options = {
                    sys_id: @system,
                    sys_name: sys.config.name,
                    mod_name: mod_name,
                    index: index,
                    status: status,
                    callback: callback,
                    on_thread: @thread
                }

                # if the module exists, subscribe on the correct thread
                # use a bit of promise magic as required
                mod_man = sys.get(mod_name, index - 1)
                sub = if mod_man
                    defer = @thread.defer

                    options[:mod_id] = mod_man.settings.id.to_sym
                    options[:mod] = mod_man
                    thread = mod_man.thread
                    thread.schedule do
                        defer.resolve (
                            thread.observer.subscribe(options)
                        )
                    end

                    defer.promise
                else
                    @thread.observer.subscribe(options)
                end

                @origin.add_subscription sub if @origin
                sub
            end

            # Is called when the system is completely loaded. Useful for logic module communication.
            #
            # @param callback [Proc] method, block, proc or lambda to be called when load is complete
            # @return [::Libuv::Q::Promise] load complete promise object
            def load_complete(callback = nil, &blk)
                callback = callback || blk

                # We create a new promise that resolves on this thread
                defer = @thread.defer
                
                promise = ::Orchestrator::Control.instance.ready_promise
                promise.then do
                    @thread.schedule do
                        defer.resolve(true)
                        callback.call if callback
                    end
                end

                defer.promise
            end


            protected


            def system
                ::Orchestrator::System.get(@system)
            end
        end
    end
end
