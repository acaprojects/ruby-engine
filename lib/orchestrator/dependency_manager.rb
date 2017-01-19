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
            class_object = @dependencies[class_lookup]

            if class_object && force == false
                defer.resolve(class_object)
            else
                begin
                    # We need to ensure only one file loads at a time
                    klass = @critical.synchronize {
                        perform_load(dependency.role, classname, class_lookup, force)
                    }
                    defer.resolve klass
                rescue Error::FileNotFound => e
                    # This avoids printing a stack trace that we don't need
                    defer.reject(Error::FileNotFound.new(e.message))
                rescue Exception => e
                    defer.reject(e)
                    print_error(e, 'error loading dependency')
                end
            end

            defer.promise
        end

        def load_helper(classname, role, force = false)
            class_lookup = classname.to_sym
            class_object = @dependencies[class_lookup]

            if class_object && force == false
                class_object
            else
                @critical.synchronize {
                    perform_load(role, classname, class_lookup, force)
                }
            end
        end

        def force_load(file)
            defer = @reactor.defer

            if File.exists?(file)
                begin
                    @critical.synchronize {
                        ::Kernel.load file
                    }
                    defer.resolve(file)
                rescue Exception => e
                    defer.reject(e)
                    print_error(e, 'force load failed')
                end
            else
                defer.reject(Error::FileNotFound.new("could not find '#{file}'"))
            end

            defer.promise
        end


        protected


        # Always called from within a Mutex
        def perform_load(role, classname, class_lookup, force)
            file = "#{classname.underscore}.rb"
            class_object = nil

            ::Rails.configuration.orchestrator.module_paths.each do |path|
                file_path = File.join(path, file)
                if ::File.exists?(file_path)

                    ::Kernel.load file_path
                    class_object = classname.constantize

                    case role
                    when :device
                        include_device(class_object)
                    when :service
                        include_service(class_object)
                    else
                        include_logic(class_object)
                    end

                    @dependencies[class_lookup] = class_object
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

        def print_error(e, msg = '')
            msg = String.new(msg)
            msg << "\n#{e.message}"
            msg << "\n#{e.backtrace.join("\n")}" if e.respond_to?(:backtrace) && e.backtrace.respond_to?(:join)
            @logger.error(msg)
        end
    end
end
