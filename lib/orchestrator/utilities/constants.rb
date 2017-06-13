# frozen_string_literal: true

require 'set'

module Orchestrator
    module Constants
        On = true       # On is active
        Off = false     # Off is inactive
        Down = true     # Down is usually active (projector screen for instance)
        Up = false      # Up is usually inactive
        Open = true
        Close = false
        Short = false

        On_vars = Set.new([1, true, 'true', 'True', 
                            :on, :On, 'on', 'On', 
                            :yes, :Yes, 'yes', 'Yes', 
                            'down', 'Down', :down, :Down, 
                            'open', 'Open', :open, :Open,
                            'active', 'Active', :active, :Active])
        Off_vars = Set.new([0, false, 'false', 'False',
                            :off, :Off, 'off', 'Off', 
                            :no, :No, 'no', 'No',
                            'up', 'Up', :up, :Up,
                            'close', 'Close', :close, :Close,
                            'short', 'Short', :short, :Short,
                            'inactive', 'Inactive', :inactive, :Inactive])


        def in_range(num, max, min = 0)
            num = min if num < min
            num = max if num > max
            num
        end

        def is_affirmative?(val)
            On_vars.include?(val)
        end

        def is_negatory?(val)
            Off_vars.include?(val)
        end

        # These are helpers for defining module config
        module ConfigMethods
            # Outputs a valid config object based on what was defined at the class level
            def __default_config(instance)
                config = {}.merge!(@config || {})

                if @tokenize
                    # Check for abstract tokenizer
                    cb = @tokenize[:callback]
                    if cb
                        token = {}.merge!(@tokenize)

                        # Were we passed a proc?
                        if !cb.respond_to?(:call)
                            token[:callback] = instance.method(cb.to_sym)
                        end

                        config[:tokenize] = proc {
                            ::UV::AbstractTokenizer.new(token)
                        }
                        wait = token[:wait_ready]
                        config[:wait_ready] = wait if wait
                    else
                        config.merge!(@tokenize)
                        config[:tokenize] = true
                    end
                end

                if @before_transmit
                    callbacks = []

                    # Normalise
                    @before_transmit.each do |cb|
                        if cb.respond_to?(:call)
                            callbacks << cb
                        else
                            callbacks << instance.method(cb.to_sym)
                        end
                    end

                    # We want to create a callback chain if more than one
                    before_transmit = if callbacks.length > 1
                        lambda do |data|
                            callbacks.each do |cb|
                                data = cb.call(data)
                            end 
                            data
                        end
                    else
                        callbacks[0]
                    end

                    # Set the config
                    config[:before_transmit] = before_transmit
                end

                config
            end

            def __default_opts(instance)
                {}.merge!(@request || {})
            end

            # Called each time the class is reloaded so we can
            # support live code updates
            def __reset_config
                @request = nil if @request
                @config = nil if @config
                @tokenize = nil if @tokenize
                @before_transmit = nil if @before_transmit
            end

            # Apply config to child classes
            def inherited(other)
                request = @request
                config = @config
                tokenize = @tokenize
                before_transmit = @before_transmit

                other.class_eval do
                    @request = request.deep_dup if request
                    @config = config.deep_dup if config
                    @tokenize = tokenize.deep_dup if tokenize
                    @before_transmit = before_transmit.dup if before_transmit
                end
            end

            def tokenize(**opts)
                if opts[:delimiter].nil?
                    if opts[:msg_length].nil? && opts[:callback].nil?
                        raise ArgumentError, 'no delimiter provided'
                    end
                end
                @tokenize = opts
            end
            alias_method :tokenise, :tokenize

            def delay(between_sends: nil, on_receive: nil)
                @request ||= {}
                @request[:delay] = between_sends if between_sends
                @request[:delay_on_receive] = on_receive if on_receive
            end

            def wait_response(opts)
                @request ||= {}
                if opts == false
                    @request[:wait] = false
                else
                    @request.merge! opts
                end
            end

            def before_transmit(*args)
                @before_transmit ||= []
                @before_transmit += args
            end

            def queue_priority(default: 50, bonus: 20)
                @config ||= {}
                @config[:priority_bonus] = bonus

                @request ||= {}
                @request[:priority] = default
            end

            def clear_queue_on_disconnect!
                @config ||= {}
                @config[:clear_queue_on_disconnect] = true
            end

            def flush_buffer_on_disconnect!
                @config ||= {}
                @config[:flush_buffer_on_disconnect] = true
            end

            # ----------------------
            # Make and Break Config:
            # ----------------------

            def inactivity_timeout(time)
                @config ||= {}
                @config[:inactivity_timeout] = time
            end


            # ------------------------
            # Service module specific:
            # ------------------------

            # val = bool
            def keepalive(val)
                @request ||= {}
                @request[:keepalive] = !!val
            end

            # opts = {user:,password:,domain:}
            def ntlm_credentials(opts)
                @config ||= {}
                @config[:ntlm] = opts
            end

            # opts = {user:,password:}
            def digest_credentials(opts)
                @config ||= {}
                @config[:digest] = opts
            end
        end


        # These are helpers for defining module config
        module DiscoverMethods
            def __discovery_details
                @makebreak = false unless @makebreak

                cfg = {}
                cfg[:role] = @implements if @implements
                cfg[:name] = @descriptive_name if @descriptive_name
                cfg[:description] = @driver_description if @driver_description
                cfg[:default] = @default_value if @default_value
                cfg[:module_name] = @generic_name if @generic_name
                cfg[:settings] = @default_settings if @default_settings
                cfg[:makebreak] = @makebreak
                cfg
            end

            def tcp_port(value)
                @default_value = value.to_i
                @implements = :device
            end

            def makebreak!
                @makebreak = true
            end

            def udp_port(value)
                @default_value = value.to_i
                @implements = :device
            end

            def uri_base(value)
                @default_value = value
                @implements = :service
            end

            Roles = [:device, :service, :logic]
            def implements(role)
                val = role.to_sym
                @implements = role if Roles.include?(val)
            end

            def generic_name(name)
                @generic_name = name
            end

            def descriptive_name(name)
                @descriptive_name = name
            end

            def description(markdown)
                @driver_description = markdown
            end

            def default_settings(json)
                @default_settings = json
            end
        end


        def self.included(klass)
            klass.extend ConfigMethods
            klass.extend DiscoverMethods
            klass.__reset_config
        end
    end
end
