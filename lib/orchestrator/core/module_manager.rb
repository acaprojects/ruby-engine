# frozen_string_literal: true

module Orchestrator
    module Core
        class ModuleManager
            def initialize(thread, klass, settings)
                @thread = thread        # Libuv Loop
                @settings = settings    # Database model
                @klass = klass

                @running = false

                # Bit of a hack - should make testing pretty easy though
                @status = ::Concurrent::Map.new
                @stattrak = @thread.observer
                @logger = ::Orchestrator::Logger.new(@thread, @settings)

                @nodes = Control.instance.nodes
            end


            attr_reader :thread, :settings, :running, :klass
            attr_reader :status, :stattrak, :logger


            # Use fiber local variables for storing the current user
            def current_user=(user)
                Thread.current[:user] = user
            end

            def current_user
                Thread.current[:user]
            end


            # Looks up the remote edge, if any for the module.
            # irrelevant of whether the module is running on this machine or not
            #
            # @return [Remote::Proxy|nil]
            def remote_node
                # Grab the edge the module should be running on
                edge = @nodes[@settings.edge_id.to_sym]
                if edge.should_run_on_this_host
                    edge = @nodes[edge.node_master_id]
                end

                # Ensure the edge we selected is not this host
                if edge && !edge.should_run_on_this_host
                    proxy = edge.proxy
                    yield proxy if proxy
                    proxy
                else
                    nil
                end
            end


            def instance
                return @instance if @instance
                if @settings.node.host_active?
                    nil
                else
                    @settings.node
                end
            end


            # Should always be called on the module thread
            def stop
                stop_local
                update_running_status(false)
            end

            def stop_local
                @running = false
                return if @instance.nil?

                begin
                    if @instance.respond_to? :on_unload, true
                        @instance.__send__(:on_unload)
                    end
                rescue => e
                    @logger.print_error(e, 'error in module unload callback')
                ensure
                    @scheduler.clear if @scheduler
                    if @subsciptions
                        unsub = @stattrak.method(:unsubscribe)
                        @subsciptions.each &unsub
                        @subsciptions = nil
                    end
                    @instance = nil
                end
            end

            def start
                begin
                    start_local(true) if @settings.node.host_active?
                    update_running_status(true)
                    true # for REST API
                rescue => e
                    @logger.print_error(e, 'module failed to start')
                    false
                end
            end

            def start_local(_ = nil)
                @running = true
                return true unless @instance.nil?

                config = self
                @instance = @klass.new
                @instance.instance_eval { @__config__ = config }

                # Apply the default config
                apply_config

                if @instance.respond_to? :on_load, true
                    @thread.next_tick do
                        begin
                            @instance.__send__(:on_load)
                        rescue => e
                            @logger.print_error(e, 'error in module load callback')
                        end
                    end
                end
            end

            def reloaded(mod)
                # Eager load dependency data
                begin
                    mod.dependency
                rescue => e
                    @logger.print_error(e, 'error eager loading dependency data')
                    mod = @settings # Keep the existing settings as these are probably loaded
                end

                @thread.schedule do
                    # pass in any updated settings
                    @settings = mod

                    if @instance
                        apply_config

                        if @instance.respond_to? :on_update, true
                            begin
                                @instance.__send__(:on_update)
                            rescue => e
                                @logger.print_error(e, 'error in module update callback')
                            end
                        end
                    end
                end
            end

            def get_scheduler
                @scheduler ||= ::Orchestrator::Core::ScheduleProxy.new(@thread, self)
            end

            # @return [::Orchestrator::Core::SystemProxy]
            def get_system(id)
                ::Orchestrator::Core::SystemProxy.new(@thread, id.to_sym, self)
            end

            # Called from Core::Mixin - thread safe
            def trak(name, value, remote = true)
                if @status[name] != value
                    @status[name] = value

                    # Allows status to be updated in workers
                    # For the most part this will run straight away
                    @thread.schedule do
                        @stattrak.update(@settings.id, name, value)
                    end

                    if remote
                        proxy = @nodes[Remote::NodeId].proxy
                        if proxy
                            @thread.schedule do
                                proxy.set_status(@settings.id, name, value)
                            end
                        end
                    end

                    # Check level to speed processing
                    if @logger.level == 0
                        @logger.debug "Status updated: #{name} = #{value}"
                    end
                elsif @logger.level == 0
                    @logger.debug "No change for: #{name} = #{value}"
                end
            end

            # Allows you to force a status update
            # Useful if you've editited an array or hash
            def signal_status(name)
                value = @status[name]
                @thread.schedule do
                    @stattrak.update(@settings.id.to_sym, name, value, true)
                end

                # Check level to speed processing
                if @logger.level == 0
                    @logger.debug "Status update signalled: #{name} = #{value}"
                end
            end

            # Subscribe to status updates from status in the same module
            # Called from Core::Mixin always on the module thread
            def subscribe(status, callback)
                sub = @stattrak.subscribe({
                    on_thread: @thread,
                    callback: callback,
                    status: status.to_sym,
                    mod_id: @settings.id.to_sym,
                    mod: self
                })
                add_subscription sub
                sub
            end

            # Called from Core::Mixin always on the module thread
            def unsubscribe(sub)
                @subsciptions.delete sub
                @stattrak.unsubscribe(sub)
            end

            # Called from subscribe and SystemProxy.subscribe always on the module thread
            def add_subscription(sub)
                @subsciptions ||= Set.new
                @subsciptions.add sub
            end

            # Called from Core::Mixin on any thread
            # For Logics: instance -> system -> zones -> dependency
            # For Device: instance -> dependency
            def setting(name)
                res = @settings.settings[name]
                id  = @settings.id

                # As we don't continually go to the database we should
                # ensure that every module has a unique copy of settings
                # as they may modify the hash
                return decrypt_value(id, name, res.deep_dup) unless res.nil?

                id = @settings.control_system_id
                if id
                    sys = System.get(id)
                    res = sys.settings[name]

                    # Check if zones have the setting
                    if res.nil?
                        sys.zones.each do |zone|
                            res = zone.settings[name]
                            return decrypt_value(zone.id, name, res.deep_dup) unless res.nil?
                        end

                        # Fallback to the dependency
                        res = @settings.dependency.settings[name]
                        id  = @settings.dependency.id
                    end
                else
                    # Fallback to the dependency
                    res = @settings.dependency.settings[name]
                    id  = @settings.dependency.id
                end

                return nil if res.nil?
                decrypt_value(id, name, res.deep_dup)
            end

            # Perform decryption work in the thread pool as we don't want to block the reactor
            def decrypt_value(id, key, val)
                if val.is_a?(String) && val[0] == "\e"
                    return thread.work { ::Orchestrator::Encryption.decode_setting(id, key, v) }.value
                end
                @last_id = id
                val
            end

            # Performs a more time consuming decryption
            # Seperated from regular setting lookup to avoid the performance hit
            def decrypt(name)
                val = setting(name)
                if val.is_a?(Hash)
                    id = @last_id # Save the id for currying (might change otherwise)
                    return thread.work { deep_decrypt(id, val) }.value
                end
                val
            end

            # Decrypts any encrypted keys that occur in the hash
            def deep_decrypt(id, hash)
                hash.each do |k, v|
                    if v.is_a?(Hash)
                        deep_decrypt(id, v)
                    elsif v.is_a?(String) && v[0] == "\e"
                        hash[k] = ::Orchestrator::Encryption.decode_setting(id, k, v)
                    end
                end
            end

            # Called from Core::Mixin on any thread
            #
            # We have to replace the structure as other threads may be
            # reading from the old structure and the settings hash is not
            # thread safe
            def define_setting(name, value)
                mod = Orchestrator::Module.find(@settings.id)
                values = mod.settings.dup
                values[name] = value
                mod.settings = values
                mod.save!(with_cas: true)
                @settings = mod
                value # Don't leak direct access to the database model
            end


            # override the default inspect method
            # This provides relevant information and won't blow the stack on an error
            def inspect
                "#<#{self.class}:0x#{self.__id__.to_s(16)} @thread=#{@thread.inspect} running=#{!@instance.nil?} managing=#{@klass.to_s} id=#{@settings.id}>"
            end


            # Stub for performance purposes
            def apply_config; end


            protected


            def update_connected_status(connected)
                id = settings.id

                model = ::Orchestrator::Module.find_by_id id
                return unless model && model.connected != connected

                tries = 0
                begin
                    model.connected = connected
                    model.updated_at = Time.now.to_i
                    model.save!(with_cas: true)
                    @settings = model
                rescue => e
                    tries += 1
                    if tries < 5
                        model = ::Orchestrator::Module.find_by_id id
                        retry
                    end
                    
                    # report any errors updating the model
                    @logger.print_error(e, 'error updating connected state in database model')

                    nil
                end
            end

            def update_running_status(running)
                model = ::Orchestrator::Module.find_by_id settings.id
                return nil unless model && model.running != running

                tries = 0
                begin
                    model.running = running
                    model.connected = false if !running
                    model.updated_at = Time.now.to_i
                    model.save!(with_cas: true)
                    @settings = model
                rescue => e
                    tries += 1
                    if tries < 5
                        model = ::Orchestrator::Module.find_by_id settings.id
                        retry
                    end
                    # report any errors updating the model
                    @logger.print_error(e, 'error updating running state in database model')
                    nil
                end
            end
        end
    end
end
