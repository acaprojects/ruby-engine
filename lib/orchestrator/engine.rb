# frozen_string_literal: true

require 'set'

module Orchestrator
    class Engine < ::Rails::Engine
        isolate_namespace Orchestrator


        # NOTE:: if we ever have any tasks
        #rake_tasks do
        #    load "tasks/orchestrator_tasks.rake"
        #end

        #
        # Define the application configuration
        #
        config.before_initialize do |app|                        # Rails.configuration
            app.config.orchestrator = ActiveSupport::OrderedOptions.new
            app.config.orchestrator.module_paths = []

            # Authentication stack is different
            app.config.middleware.insert_after Rack::Runtime, SelectiveStack

            # This is for trigger emails
            app.config.orchestrator.backoffice_url = 'https://example.domain/backoffice'

            # Clearance levels defined in code
            #app.config.orchestrator.clearance_levels = Set.new([:Admin, :Support, :User, :Public])

            # Access checking callback - used at the system level
            # Will always be passed a system id and the user attempting to access
            app.config.orchestrator.check_access = proc { |system, user|
                true
            }

            # if not zero all UDP sockets must be transmitted from a single thread
            app.config.orchestrator.datagram_bind = '0.0.0.0'
            app.config.orchestrator.datagram_port = 0    # ephemeral port (random selection)
            app.config.orchestrator.broadcast_port = 0   # ephemeral port (random selection)

            # Don't autoload modules - they could depend on orchestrator features
            module_paths = []
            ::Rails.application.config.eager_load_paths.each do |path|
                module_paths << path if path.end_with? 'app/modules'
            end
            ::Rails.application.config.eager_load_paths -= module_paths
        end

        #
        # Discover the possible module location paths after initialization is complete
        #
        config.after_initialize do |app|
            require File.expand_path(File.join(File.expand_path("../", __FILE__), '../../app/models/user'))

            # Increase the default observe timeout
            # TODO:: We should really be writing our own DB adaptor
            ::User.bucket.default_observe_timeout = 10000000
            
            ActiveSupport::Dependencies.autoload_paths.each do |path|
                Pathname.new(path).ascend do |v|
                    if ['app', 'vendor', 'lib'].include?(v.basename.to_s)
                        app.config.orchestrator.module_paths << File.expand_path(File.join(v.to_s, '../modules'))
                        app.config.orchestrator.module_paths << File.expand_path(File.join(v.to_s, 'modules'))
                        break
                    end
                end
            end

            app.config.orchestrator.module_paths.uniq!

            # Force design documents
            temp = ::Couchbase::Model::Configuration.design_documents_paths

            ::Couchbase::Model::Configuration.design_documents_paths = [File.expand_path(File.join(File.expand_path("../", __FILE__), '../../app/models/orchestrator'))]
            ::Orchestrator::ControlSystem.ensure_design_document!
            ::Orchestrator::Module.ensure_design_document!
            ::Orchestrator::Zone.ensure_design_document!
            ::Orchestrator::TriggerInstance.ensure_design_document!
            ::Orchestrator::EdgeControl.ensure_design_document!

            ::Couchbase::Model::Configuration.design_documents_paths = [File.expand_path(File.join(File.expand_path("../", __FILE__), '../../app/models'))]
            ::User.ensure_design_document!

            ::Couchbase::Model::Configuration.design_documents_paths = temp

            # Start the control system by initializing it
            ctrl = ::Orchestrator::Control.instance

            # Don't auto-load if running in the console or as a rake task
            unless ENV['ORC_NO_BOOT'] || defined?(Rails::Console) || Rails.env.test? || defined?(Rake)
                ctrl.reactor.next_tick do
                    begin
                        ctrl.mount.then ctrl.method(:boot)
                    rescue Exception => e # Exception is valid here as process kill will be more effective
                        # Issue would have been caused by a database error in the ctrl.mount function
                        # We really need the system to be in a clean state when it starts so our only
                        # option is to kill it and let the service manager restart it.
                        Process.kill 'SIGKILL', Process.pid
                        abort("Failed to load. Killing process.")
                    end
                end
            end
        end
    end
end
