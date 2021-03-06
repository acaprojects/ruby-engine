# frozen_string_literal: true

require 'set'
require 'mono_logger'
require 'active_support/all'
require 'spider-gazelle'
require 'spider-gazelle/spider'
require 'lograge'

module Orchestrator
    class Engine < ::Rails::Engine
        isolate_namespace Orchestrator

        #
        # Define the application configuration
        #
        config.before_initialize do |app|                        # Rails.configuration
            app.config.orchestrator = ActiveSupport::OrderedOptions.new
            app.config.orchestrator.load_path = ::Dir.pwd
            app.config.orchestrator.module_paths = []

            # This is for trigger emails
            app.config.orchestrator.backoffice_url = 'https://example.domain/backoffice'

            # Clearance levels defined in code
            #app.config.orchestrator.clearance_levels = Set.new([:Admin, :Support, :User, :Public])
            STDOUT.sync = true
            STDERR.sync = true
            ::SpiderGazelle::Spider.instance.delay_port_binding

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

            # configure single line logging
            app.config.lograge.enabled = true
            app.config.lograge.base_controller_class = ['ActionController::API', 'ActionController::Base']
            app.config.lograge.custom_payload do |controller|
              user = controller.respond_to?(:current_user, true) ? controller.__send__(:current_user) : nil
              user = user ? user.id : "anonymous"
              {
                time: Time.now,
                user_id: user
              }
            end

            # Start the control system by initializing it
            ctrl = ::Orchestrator::Control.instance

            # Configure 90 second timeouts as we share the reactor loop
            # 0, 1, 13, 15, 61, 93 == operations, views, http, v-bucket poll, n1ql, http pool
            ::User.bucket.connection.reactor.schedule do
                handle = ::User.bucket.connection.handle
                ::Libcouchbase::Ext.cntl_setu32(handle, 0, 90_000_000)
                ::Libcouchbase::Ext.cntl_setu32(handle, 1, 90_000_000)
                ::Libcouchbase::Ext.cntl_setu32(handle, 13, 90_000_000)
                ::Libcouchbase::Ext.cntl_setu32(handle, 15, 90_000_000)
                ::Libcouchbase::Ext.cntl_setu32(handle, 61, 90_000_000)
                ::Libcouchbase::Ext.cntl_setu32(handle, 93, 90_000_000)


                # Configure retries
                # LCB_RETRYOPT_CREATE = Proc.new { |mode, policy| ((mode << 16) | policy) }
                # val = LCB_RETRYOPT_CREATE(LCB_RETRY_ON_SOCKERR, LCB_RETRY_CMDS_SAFE);
                # ::Libcouchbase::Ext.cntl_setu32(handle, LCB_CNTL_RETRYMODE, val)
                retry_config = (1 << 16) | 3
                ::Libcouchbase::Ext.cntl_setu32(handle, 0x24, retry_config)
            end

            # Don't auto-load if running in the console or as a rake task
            if ENV['ORC_NO_BOOT'] || defined?(Rails::Console) || Rails.env.test? || defined?(::Rake::Task)
                ::SpiderGazelle::Spider.instance.bind_application_ports
            else
                ctrl.reactor.next_tick do
                    begin
                        ctrl.mount.then { ctrl.boot }
                    rescue Exception => e # Exception is valid here as process kill will be more effective
                        # Issue would have been caused by a database error in the ctrl.mount function
                        # We really need the system to be in a clean state when it starts so our only
                        # option is to kill it and let the service manager restart it.
                        STDERR.puts "Failed to load: #{e.message}\n#{e.backtrace.join("\n")}"
                        STDERR.flush
                        Process.kill 'INT', Process.pid
                    end
                end
            end
        end
    end
end
