# frozen_string_literal: true

require 'monitor'
require 'set'

module Orchestrator
    class DependencyManager
        include Singleton

        def self.load(classname, role, force = true)
            DependencyManager.instance.load_helper(classname.to_s, role.to_sym, force)
        end

        def initialize
            @critical = Monitor.new
            @dependencies = Concurrent::Map.new
            @reactor = ::Libuv::Reactor.default
            @reactor.next_tick do
                @logger = ::Orchestrator::Control.instance.logger
            end
        end

        def load(dependency, force = false)
            defer = @reactor.defer

            classname = dependency.class_name
            class_lookup = classname.to_sym

            begin
                defer.resolve(load_helper(classname, dependency.role, force))
            rescue Exception => e
                msg = String.new(e.message)
                msg << "\n#{e.backtrace.join("\n")}" if e&.backtrace&.respond_to?(:join)
                @logger.error(msg)
                defer.reject(e)
            end

            defer.promise
        end

        def load_helper(classname, role, force = false)
            class_lookup = classname.to_sym

            if not force
                class_object = @dependencies[class_lookup]
                return class_object if class_object
            end

            if @reactor.reactor_thread?
                @reactor.work {
                    perform_load(role, classname, class_lookup)
                }.value
            else
                perform_load(role, classname, class_lookup)
            end
        end

        def force_load(file)
            defer = @reactor.defer

            if File.exists?(file)
                if @reactor.reactor_thread?
                    defer.resolve(@reactor.work {
                        @critical.synchronize { ::Kernel.load file }
                        file
                    })
                else
                    begin
                        @critical.synchronize { ::Kernel.load file }
                        defer.resolve(file)
                    rescue Exception => e
                        defer.reject(e)
                    end
                end
            else
                defer.reject(Error::FileNotFound.new("could not find '#{file}'"))
            end

            defer.promise
        end


        protected


        # Always called from within a Mutex
        def perform_load(role, classname, class_lookup)
            file = "#{classname.underscore}.rb"
            class_object = nil

            ::Rails.configuration.orchestrator.module_paths.each do |path|
                file_path = File.join(path, file)

                if ::File.exists?(file_path)
                    @critical.synchronize {
                        ::Kernel.load file_path
                        class_object = classname.constantize

                        case role
                        when :ssh
                            include_ssh(class_object)
                        when :device
                            include_device(class_object)
                        when :service
                            include_service(class_object)
                        when :model
                            # We're basically just force loading a file here
                        else
                            include_logic(class_object)
                        end

                        @dependencies[class_lookup] = class_object
                    }
                    break
                end
            end

            if class_object.nil?
                raise Error::FileNotFound.new("could not find '#{file}'")
            end

            class_object
        end

        def include_logic(klass)
            klass.class_eval do
                include ::Orchestrator::Logic::Mixin
            end
        end

        def include_device(klass)
            klass.class_eval do
                include ::Orchestrator::Device::Mixin
            end
        end

        def include_service(klass)
            klass.class_eval do
                include ::Orchestrator::Service::Mixin
            end
        end

        def include_ssh(klass)
            klass.class_eval do
                include ::Orchestrator::Ssh::Mixin
            end
        end
    end
end
