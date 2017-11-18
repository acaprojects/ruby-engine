# frozen_string_literal: true

module Orchestrator
    module Core

        #
        # This class exists so that we can access regular kernel methods
        class RequestsForward
            def initialize(thread, modules, user)
                @modules = Array(modules)
                @thread = thread
                @user = user
                @trace = []
            end

            attr_reader :trace
            attr_reader :modules

            # Provide Enumerable support
            def each
                return enum_for(:each) unless block_given?

                @modules.each do |mod|
                    yield RequestProxy.new(@thread, mod, @user)
                end
            end

            def last
                mod = @modules.last
                return nil unless mod
                return RequestProxy.new(@thread, mod, @user)
            end

            def first
                mod = @modules.first
                return nil unless mod
                return RequestProxy.new(@thread, mod, @user)
            end

            def [](index)
                mod = @modules[index]
                return nil unless mod
                return RequestProxy.new(@thread, mod, @user)
            end

            def request(name, args, &block)
                if ::Orchestrator::Core::PROTECTED[name]
                    err = Error::ProtectedMethod.new "attempt to access a protected method '#{name}' in multiple modules"
                    ::Libuv::Q.reject(@thread, err)
                    # TODO:: log warning err.message
                else
                    @trace = caller

                    promises = @modules.map do |mod|
                        defer = mod.thread.defer
                        mod.thread.schedule do
                            # Keep track of previous in case of recursion
                            previous = nil
                            begin
                                previous = mod.current_user
                                mod.current_user = @user

                                instance = mod.instance
                                if instance.nil?
                                    err = StandardError.new "method '#{name}' request failed as the module '#{mod.settings.id}' is currently stopped"
                                    defer.reject(err)
                                elsif instance.class == ::Orchestrator::EdgeControl
                                    proxy = instance.proxy
                                    if proxy
                                        defer.resolve(
                                            proxy.execute(mod.settings.id, name, args, @user ? @user.id : nil)
                                        )
                                    else
                                        err = StandardError.new "method '#{name}' request failed as the node '#{instance.name}' @ #{instance.host_origin} is currently offline"
                                        defer.reject(err)
                                    end
                                else
                                    if !instance.class.respond_to?(:grant_access?) || instance.class.grant_access?(instance, @user, name)
                                        defer.resolve(
                                            instance.public_send(name, *args, &block)
                                        )
                                    else
                                        msg = "#{@user.id} attempted to access secure method #{name}"
                                        mod.logger.warn msg
                                        defer.reject(SecurityError.new(msg))
                                    end
                                end
                            rescue => e
                                defer.reject(e)
                                mod.logger.print_error(e, "issue calling #{name} with #{args.inspect}", @trace)
                            ensure
                                mod.current_user = previous
                            end
                        end
                        defer.promise
                    end

                    @thread.finally(*promises)
                end
            end
        end

        # By using basic object we should be almost perfectly proxying the module code
        class RequestsProxy < BasicObject
            include ::Enumerable

            def initialize(thread, modules, user = nil)
                @forward = RequestsForward.new(thread, modules, user)
                @modules = @forward.modules
            end

            def trace
                @forward.trace
            end

            # Provide Enumerable support
            def each(&blk)
                @forward.each &blk
            end

            # Shortcut some methods (reduce object creation)
            def count; @modules.count; end
            def length; @modules.length; end
            def empty?; @modules.empty?; end
            def each_index; @modules.each_index(&block); end

            def last
                @forward.last
            end

            def first
                @forward.first
            end

            def [](index)
                @forward[index]
            end

            def at(index)
                @forward[index]
            end

            # Returns true if there is no object to proxy
            # Allows RequestProxy and RequestsProxy to be used interchangably
            #
            # @return [true|false]
            def nil?
                @modules.empty?
            end

            def method_missing(name, *args, &block)
                @forward.request(name.to_sym, args, &block)
            end

            def send(name, *args, &block)
                @forward.request(name.to_sym, args, &block)
            end

            # Add support for inspecting the object
            def inspect
                if @user
                    "#{@modules.inspect} as user: #{@user.id}"
                else
                    @modules.inspect
                end
            end

            def hash
                inspect.hash
            end

            def ==(other)
                case other
                when RequestsProxy
                    hash == other.hash
                else
                    false
                end
            end
        end
    end
end
