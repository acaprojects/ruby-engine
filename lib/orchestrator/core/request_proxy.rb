# frozen_string_literal: true

require 'pp'

module Orchestrator
    module Core
        PROTECTED = ::Concurrent::Map.new
        PROTECTED[:unsubscribe] = true
        PROTECTED[:subscribe] = true
        PROTECTED[:schedule] = true
        PROTECTED[:systems] = true
        #PROTECTED[:setting] = true # settings might be useful
        PROTECTED[:system] = true
        PROTECTED[:logger] = true
        PROTECTED[:task] = true
        PROTECTED[:wake_device] = true

        # Object functions
        PROTECTED[:__send__] = true
        PROTECTED[:public_send] = true
        PROTECTED[:taint] = true
        PROTECTED[:untaint] = true
        PROTECTED[:trust] = true
        PROTECTED[:untrust] = true
        PROTECTED[:freeze] = true

        # Callbacks
        PROTECTED[:on_load] = true
        PROTECTED[:on_unload] = true
        PROTECTED[:on_update] = true
        PROTECTED[:connected] = true
        PROTECTED[:disconnected] = true
        PROTECTED[:received] = true

        # Device module
        PROTECTED[:send] = true
        PROTECTED[:defaults] = true
        PROTECTED[:disconnect] = true
        PROTECTED[:config] = true

        # Service module
        PROTECTED[:get] = true
        PROTECTED[:put] = true
        PROTECTED[:post] = true
        PROTECTED[:delete] = true
        PROTECTED[:request] = true
        PROTECTED[:clear_cookies] = true
        PROTECTED[:use_middleware] = true

        # SSH module
        PROTECTED[:exec] = true

        [
            Constants, Transcoder, Core::Mixin, Ssh::Mixin,
            Logic::Mixin, Device::Mixin, Service::Mixin,
            ::ActiveSupport::ToJsonWithActiveSupportEncoder,
            Object, Kernel, BasicObject, PP::ObjectMixin
        ].each do |klass|
            klass.instance_methods(true).each do |method|
              PROTECTED[method] = true
            end
        end

        # This class exists so that we can access regular kernel methods
        class RequestForward
            def initialize(thread, mod, user = nil)
                @mod = mod
                @thread = thread
                @user = user
                @trace = []
            end

            attr_reader :trace, :user

            def request(name, args, &block)
                defer = @thread.defer

                if @mod.nil?
                    err = Error::ModuleUnavailable.new "method '#{name}' request failed as the module is not available at this time"
                    defer.reject(err)
                    # TODO:: debug log here
                elsif ::Orchestrator::Core::PROTECTED[name]
                    err = Error::ProtectedMethod.new "attempt to access module '#{@mod.settings.id}' protected method '#{name}'"
                    defer.reject(err)
                    @mod.logger.warn(err.message)
                else
                    @trace = caller

                    @mod.thread.schedule do
                        # Keep track of previous in case of recursion
                        previous = nil
                        begin
                            previous = @mod.current_user
                            @mod.current_user = @user

                            instance = @mod.instance
                            if instance.nil?
                                if @mod.running == false
                                    err = StandardError.new "method '#{name}' request failed as the module '#{@mod.settings.id}' is currently stopped"
                                    defer.reject(err)
                                else
                                    logger.warn "the module #{@mod.settings.id} is currently stopped however should be running. Attempting restart"
                                    if @mod.start_local
                                        if !instance.class.respond_to?(:grant_access?) || instance.class.grant_access?(instance, @user, name)
                                            defer.resolve(@mod.instance.public_send(name, *args, &block))
                                        else
                                            msg = "#{@user.id} attempted to access secure method #{name}"
                                            @mod.logger.warn msg
                                            defer.reject(SecurityError.new(msg))
                                        end
                                    else
                                        err = StandardError.new "method '#{name}' request failed as the module '#{@mod.settings.id}' failed to start"
                                        defer.reject(err)
                                    end
                                end
                            elsif instance.class == ::Orchestrator::Remote::Manager
                                proxy = instance.proxy
                                if proxy
                                    defer.resolve(proxy.execute(@mod.settings.id, name, args, @user ? @user.id : nil))
                                else
                                    err = StandardError.new "method '#{name}' request failed as the node '#{instance.name}' @ #{instance.host_origin} is currently offline"
                                    defer.reject(err)
                                end
                            else
                                if !instance.class.respond_to?(:grant_access?) || instance.class.grant_access?(instance, @user, name)
                                    defer.resolve(instance.public_send(name, *args, &block))
                                else
                                    msg = "#{@user.id} attempted to access secure method #{name}"
                                    @mod.logger.warn msg
                                    defer.reject(SecurityError.new(msg))
                                end
                            end
                        rescue => e
                            defer.reject(e)
                            @mod.logger.print_error(e, "issue calling #{name} with #{args.inspect}", @trace)
                        ensure
                            @mod.current_user = previous
                        end
                    end
                end

                defer.promise
            end

            def respond_to?(symbol, include_all)
                if @mod
                    @mod.instance.respond_to?(symbol, include_all)
                else
                    false
                end
            end
        end

        # By using basic object we should be almost perfectly proxying the module code
        class RequestProxy < BasicObject
            def initialize(thread, mod, user = nil)
                @mod = mod
                @forward = RequestForward.new(thread, mod, user)
            end

            def trace
                @forward.trace
            end

            # Simplify access to status variables as they are thread safe
            def [](name)
                @mod.instance[name]
            end

            def []=(status, value)
                @mod.instance[status] = value
            end

            # Returns true if there is no object to proxy
            #
            # @return [true|false]
            def nil?
                (@mod&.instance).nil?
            end

            # Returns true if the module responds to the given method
            #
            # @return [true|false]
            def respond_to?(symbol, include_all = false)
                @forward.respond_to?(symbol, include_all)
            end

            # Looks up the arity of a method
            def arity(method)
                @mod.instance.method(method.to_sym).arity
            end

            # All other method calls are wrapped in a promise
            def method_missing(name, *args, &block)
                @forward.request(name.to_sym, args, &block)
            end

            def send(name, *args, &block)
                @forward.request(name.to_sym, args, &block)
            end

            # Add support for inspecting the object
            def inspect
                return nil.inspect if @mod.nil?

                user = @forward.user
                if user
                    "#{@mod.instance.inspect} as user: #{user.id}"
                else
                    @mod.instance.inspect
                end
            end

            def hash
                inspect.hash
            end

            def ==(other)
                case other
                when RequestProxy
                    hash == other.hash
                else
                    false
                end
            end
        end
    end
end
