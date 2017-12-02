# frozen_string_literal: true

module Orchestrator
    module Remote
        class Manager
            def initialize(thread, klass, settings)
                @thread = thread        # Libuv Loop
                @settings = settings    # Database model
                @klass = klass
                @stattrak = @thread.observer
            end

            attr_reader :thread, :settings, :klass, :stattrak


            def running
                proxy.running?(@settings.id).value
            end

            # Use fiber local variables for storing the current user
            def current_user=(user)
                Thread.current[:user] = user
            end

            def current_user
                Thread.current[:user]
            end


            # Basic Operations
            def stop
                proxy.stop(@settings.id)
            end

            def start
                proxy.start(@settings.id)
            end


            # This returns self for status 
            def instance
                self
            end

            def proxy
                Control.instance.get_node_proxy(@settings.edge_id.to_sym)
            end

            def reloaded(mod_settings)
                proxy.update_settings(mod_settings.id, mod_settings)
            end


            # Status query / update from remote node
            def status
                self
            end

            def []=(name, value)
                proxy.set_status(@settings.id, name, value)
                value
            end

            def [](name)
                proxy.status(@settings.id, name).value
            end

            def inspect
                "#<#{self.class}:0x#{self.__id__.to_s(16)} managing=#{@klass.to_s} id=#{@settings.id} remote_node_connected=#{proxy.connected?}>"
            end

            # TODO:: __STATS__
        end
    end
end
