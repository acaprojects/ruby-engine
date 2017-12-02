# frozen_string_literal: true

require 'set'
require 'json'

module Orchestrator
    class WebsocketManager
        def initialize(ws, user, fixed_device, ip)
            @ws = ws
            @user = user
            @reactor = ws.reactor

            @bindings = ::Concurrent::Map.new
            @stattrak = @reactor.observer
            @notify_update = proc { |u| notify_update(u) }

            @logger = ::Orchestrator::Logger.new(@reactor, user)

            @ws.progress { |data, ws| on_message(data, ws) }
            @ws.finally { on_shutdown }
            #@ws.on_open method(:on_open)

            @accessed = ::Set.new
            @access_log = ::Orchestrator::AccessLog.new
            @access_log.ip = ip
            @access_log.user_id = @user.id
            @access_log.installed_device = fixed_device

            @access_cache  = {}
            @access_timers = []
        end


        DECODE_OPTIONS = {
            symbolize_names: true
        }.freeze

        PARAMS = [:id, :cmd, :sys, :mod, :index, :name, {args: [].freeze}.freeze].freeze
        REQUIRED = [:id, :cmd, :sys, :mod, :name].freeze
        COMMANDS = Set.new([:exec, :bind, :unbind, :debug, :ignore])

        ERRORS = {
            parse_error: 0,
            bad_request: 1,
            access_denied: 2,
            request_failed: 3,
            unknown_command: 4,

            system_not_found: 5,
            module_not_found: 6,
            unexpected_failure: 7
        }.freeze


        protected


        def on_message(data, ws)
            if data == 'ping'
                @ws.text('pong')
                return
            end

            begin
                raw_parameters = ::JSON.parse(data, DECODE_OPTIONS)
                parameters = ::ActionController::Parameters.new(raw_parameters)
                params = parameters.permit(PARAMS).tap do |whitelist|
                    whitelist[:args] = parameters[:args]
                end
            rescue => e
                @logger.print_error(e, 'error parsing websocket request')
                error_response(nil, ERRORS[:parse_error], e.message)
                return
            end

            if check_requirements(params)
                # Perform the security check in a nonblocking fashion
                # (Database access is probably required)
                sys_id = params[:sys].to_sym
                access = @access_cache[sys_id]

                if access.nil?
                    begin
                        access = Rails.configuration.orchestrator.check_access.call(sys_id, @user)
                        @access_cache[sys_id] = access
                        expire_access(sys_id)
                    rescue => e
                        @access_log.suspected = true
                        @logger.print_error(e, 'security check failed for websocket request')
                        error_response(params[:id], ERRORS[:access_denied], e.message)
                    end
                end

                # The result should be an access level if these are implemented
                begin
                    cmd = params[:cmd].to_sym
                    if COMMANDS.include?(cmd)
                        @accessed << sys_id         # Log the access
                        self.__send__(cmd, params)  # Execute the request

                        # Start logging
                        periodicly_update_logs unless @accessTimer
                    else
                        @access_log.suspected = true
                        @logger.warn("websocket requested unknown command '#{params[:cmd]}'")
                        error_response(params[:id], ERRORS[:unknown_command], "unknown command: #{params[:cmd]}")
                    end
                rescue => e
                    @logger.print_error(e, "websocket request failed: #{data}")
                    error_response(params[:id], ERRORS[:request_failed], e.message)
                end
            else
                # log user information here (possible probing attempt)
                @access_log.suspected = true
                reason = 'required parameters were missing from the request'
                @logger.warn(reason)
                error_response(params[:id], ERRORS[:bad_request], reason)
            end
        end

        def check_requirements(params)
            REQUIRED.each do |key|
                return false unless params.has_key?(key)
            end
            true
        end


        def exec(params)
            id = params[:id]
            sys = params[:sys]
            mod = params[:mod].to_sym
            name = params[:name].to_sym
            index_s = params[:index] || 1
            index = index_s.to_i

            args = Array(params[:args])

            do_exec(id, sys, mod, index, name, args)
        end

        def do_exec(id, sys, mod, index, name, args)
            system = ::Orchestrator::System.get(sys)

            if system
                mod_man = system.get(mod, index)
                if mod_man
                    req = Core::RequestProxy.new(@reactor, mod_man, @user)
                    result = req.method_missing(name, *args)
                    result.then(proc { |res|
                        output = {
                            id: id,
                            type: :success,
                            value: prepare_json(res)
                        }

                        begin
                            @ws.text(output.to_json)
                        rescue Exception => e
                            # Probably an error generating JSON
                            @logger.debug {
                                begin
                                    "exec could not generate JSON result for #{output[:value]}"
                                rescue Exception => e
                                    "exec could not generate JSON result for return value"
                                end
                            }
                            output[:value] = nil
                            @ws.text(output.to_json)
                        end
                    }, proc { |err|
                        # Request proxy will log the error
                        error_response(id, ERRORS[:request_failed], err.message)
                    })
                else
                    @logger.debug("websocket exec could not find module: {sys: #{sys}, mod: #{mod}, index: #{index}, name: #{name}}")
                    error_response(id, ERRORS[:module_not_found], "could not find module: #{mod}")
                end
            else
                @logger.debug("websocket exec could not find system: {sys: #{sys}, mod: #{mod}, index: #{index}, name: #{name}}")
                error_response(id, ERRORS[:system_not_found], "could not find system: #{sys}")
            end
        end


        def unbind(params)
            # Check websocket hasn't shutdown
            return unless @bindings

            id = params[:id]
            sys = params[:sys]
            mod = params[:mod]
            name = params[:name]
            index_s = params[:index] || 1
            index = index_s.to_i

            lookup = :"#{sys}_#{mod}_#{index}_#{name}"
            binding = @bindings.delete(lookup)
            do_unbind(binding) if binding

            @ws.text({
                id: id,
                type: :success
            }.to_json)
        end

        def do_unbind(binding)
            @stattrak.unsubscribe(binding)
        end


        def bind(params)
            id = params[:id]
            sys = params[:sys].to_sym
            mod = params[:mod].to_sym
            name = params[:name].to_sym
            index_s = params[:index] || 1
            index = index_s.to_i

            # perform binding on the thread pool
            begin
                check_binding(id, sys, mod, index, name)
            rescue => err
                @logger.print_error(err, "websocket request failed: #{params}")
                error_response(id, ERRORS[:unexpected_failure], err.message)
            end
        end

        # Called from a worker thread
        def check_binding(id, sys, mod, index, name)
            # Check websocket hasn't shutdown
            return unless @bindings
            
            system = ::Orchestrator::System.get(sys)

            if system
                lookup = :"#{sys}_#{mod}_#{index}_#{name}"
                binding = @bindings[lookup]

                if binding.nil?
                    try_bind(id, sys, system, mod, index, name, lookup)
                else
                    # binding already made - return success
                    @ws.text({
                        id: id,
                        type: :success,
                        meta: {
                            sys: sys,
                            mod: mod,
                            index: index,
                            name: name
                        }
                    }.to_json)
                end
            else
                @logger.debug("websocket binding could not find system: {sys: #{sys}, mod: #{mod}, index: #{index}, name: #{name}}")
                error_response(id, ERRORS[:system_not_found], "could not find system: #{sys}")
            end
        end

        def try_bind(id, sys, system, mod_name, index, name, lookup)
            options = {
                sys_id: sys,
                sys_name: system.config.name,
                mod_name: mod_name,
                index: index,
                status: name,
                callback: @notify_update,
                on_thread: @reactor
            }

            # if the module exists, subscribe on the correct thread
            # use a bit of promise magic as required
            mod_man = system.get(mod_name, index)
            defer = @reactor.defer

            # Ensure browser sees this before the first status update
            # At this point subscription will be successful
            @bindings[lookup] = defer.promise
            @ws.text({
                id: id,
                type: :success,
                meta: {
                    sys: sys,
                    mod: mod_name,
                    index: index,
                    name: name
                }
            }.to_json)

            if mod_man
                options[:mod_id] = mod_man.settings.id.to_sym
                options[:mod] = mod_man
                thread = mod_man.thread
                thread.schedule do
                    defer.resolve (
                        thread.observer.subscribe(options)
                    )
                end
            else
                @reactor.schedule do
                    defer.resolve @stattrak.subscribe(options)
                end
            end
        end

        def notify_update(update)
            output = {
                type: :notify,
                value: prepare_json(update.value),
                meta: {
                    sys: update.sys_id,
                    mod: update.mod_name,
                    index: update.index,
                    name: update.status
                }
            }

            begin
                @ws.text(output.to_json)
            rescue Exception => e
                # respond with nil if object cannot be converted
                begin
                    @logger.warn "status #{output[:meta]} update failed, could not generate JSON data for #{output[:value]}"
                rescue Exception => e
                    @logger.warn "status #{output[:meta]} update failed, could not generate JSON data for value"
                end
                output[:value] = nil
                @ws.text(output.to_json)
            end
        end


        def debug(params)
            id = params[:id]
            sys = params[:sys].to_sym
            mod = params[:mod].to_sym
            index_s = params[:index]
            index = nil
            index = index_s.to_i if index_s

            if @debug.nil?
                @debug = proc { |klass, mod_id, level, msg|
                    @reactor.schedule {
                        @ws.text({
                            type: :debug,
                            mod: mod_id,
                            klass: klass,
                            level: level,
                            msg: msg
                        }.to_json)
                    }
                }
                @inspecting = Set.new
            end

            if index
                # Look up the module ID
                begin
                    system = ::Orchestrator::System.get(sys)
                    if system
                        mod_man = system.get(mod, index)
                        if mod_man
                            mod_id = mod_man.settings.id.to_sym
                            do_debug(id, mod_id, sys, mod, index)
                        else
                            msg = "debug failed: module #{sys}->#{mod}_#{index} not found"
                            @logger.info(msg)
                            error_response(id, ERRORS[:module_not_found], msg)
                        end
                    else
                        msg = "debug failed: system #{sys} lookup failed"
                        @logger.info(msg)
                        error_response(id, ERRORS[:module_not_found], msg)
                    end
                rescue => err
                    @logger.print_error(err, "debug request failed: #{params}")
                    error_response(id, ERRORS[:module_not_found], "debug request failed for: #{sys}->#{mod}_#{index}")
                end
            else
                do_debug(id, mod)
            end
        end

        def do_debug(id, mod, sys_id = nil, mod_name = nil, mod_index = nil)
            resp = {
                id: id,
                type: :success,
                mod_id: mod
            }

            if mod_name
                # Provide meta information for convenience
                # Actual debug messages do not contain this info
                # The library must use the mod_id returned in the response to route responses as desired
                resp[:meta] = {
                    sys: sys_id,
                    mod: mod_name,
                    index: mod_index
                }
            end

            # Set mod to get module level errors
            begin
                if @inspecting.include?(mod)
                    @ws.text(resp.to_json)
                else
                    # Set sys to get errors occurring outside of the modules
                    @logger.register @debug if @inspecting.empty?
                    @inspecting.add mod

                    mod_man = ::Orchestrator::Control.instance.loaded?(mod)
                    if mod_man
                        thread = mod_man.thread
                        thread.schedule do
                            thread.observer.debug_subscribe(mod, @debug)
                        end
                    else
                        @stattrak.debug_subscribe(mod, @debug)
                        @logger.warn("websocket debug could not find module: #{mod}")
                    end

                    @ws.text(resp.to_json)
                end
            rescue => e
                @logger.print_error(e, "websocket debug request failed")
                error_response(id, ERRORS[:request_failed], e.message)
            end
        end

        def ignore(params)
            id = params[:id]
            sys = params[:sys].to_sym
            mod_s = params[:mod]
            mod = mod_s.to_sym if mod_s

            if @inspecting && @inspecting.include?(mod)
                @inspecting.delete mod
                # Stop logging all together if no more modules being watched
                @logger.remove @debug if @inspecting.empty?
                do_ignore(mod)
            end

            @ws.text({
                id: id,
                type: :success
            }.to_json)
        end

        def do_ignore(mod_id)
            @stattrak.debug_unsubscribe(mod_id, @debug)
        end


        def error_response(id, code, message)
            @ws.text({
                id: id,
                type: :error,
                code: code,
                msg: message
            }.to_json)
        end

        def on_shutdown
            @bindings.each_value { |b| do_unbind(b) }
            @bindings = nil
            if @inspecting
                @inspecting.each { |i| do_ignore(i) }
                @inspecting = nil
            end

            if @accessTimer
                @accessTimer.cancel
                @access_log.systems = @accessed.to_a
                @access_log.ended_at = Time.now.to_i
                @access_log.save
            end

            @access_timers.each do |timer|
                timer.cancel
            end
            @access_timers.clear
        end


        protected


        def update_accessed(*args)
            @access_log.systems = @accessed.to_a
            @access_log.save!
        rescue => e
            @logger.print_error(e, "unknown error writing access log")
        end

        def periodicly_update_logs
            @accessTimer = @reactor.scheduler.every(60000 + Random.rand(1000)) { update_accessed }
            @access_log.systems = @accessed.to_a
            @access_log.save
        end

        def expire_access(sys_id)
            # Require new access check every 15min
            @access_timers << @reactor.scheduler.in(900_000) do
                @access_timers.shift
                @access_cache.delete(sys_id)
            end
        end

        def prepare_json(object)
            case object
            when nil, true, false, Hash, String, Integer, Array, Float, Symbol
                object
            else
                if object.respond_to? :to_json
                    object.to_json
                elsif object.respond_to? :to_s
                    object.to_s
                else
                    nil
                end
            end
        end
    end
end
