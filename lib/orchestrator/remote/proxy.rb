# frozen_string_literal: true

require 'radix/base'

module Orchestrator
    module Remote
        class Proxy
            B65 = ::Radix::Base.new(::Radix::BASE::B62 + ['-', '_', '~'])
            B10 = ::Radix::Base.new(10)

            def initialize(ctrl, dep_man, tcp)
                @ctrl = ctrl
                @dep_man = dep_man
                @thread = ctrl.reactor
                @tcp = tcp

                @sent = {}
                @count = 0

                # reject requests when connection fails
                tcp.finally do
                    e = RuntimeError.new('lost connection to remote node')
                    e.set_backtrace([])
                    @sent.values.each do |defer|
                        defer.reject e
                    end 
                    @sent = {}
                end
            end


            attr_reader :thread


            # ---------------------------------
            # Send commands to the remote node:
            # ---------------------------------
            def execute(mod_id, func, args = nil, user_id = nil)
                msg = {
                    type: :cmd,
                    mod: mod_id,
                    func: func
                }

                msg[:args] = Array(args) if args
                msg[:user] = user_id if user_id

                send_with_id(msg)
            end

            def status(mod_id, status_name)
                defer = @thread.defer

                msg = {
                    type: :stat,
                    mod: mod_id,
                    stat: status_name
                }

                send_with_id(msg)
            end

            def shutdown
                msg = {
                    type: :push,
                    push: :shutdown
                }
                send_direct(msg)
            end

            # TODO:: Expire System Cache
            # TODO:: Reload module, system, dependency, zone (settings update)
            # ------> Might also need to pass the settings down the wire to avoid race conditions

            def reload(dep_id)
                msg = {
                    type: :push,
                    push: :reload,
                    dep: dep_id
                }
                send_with_id(msg)
            end

            [:load, :start, :stop, :unload].each do |cmd|
                define_method cmd do |mod_id|
                    msg = {
                        type: :push,
                        push: cmd,
                        mod: mod_id
                    }
                    send_with_id(msg)
                end
            end

            def set_status(mod_id, status_name, value)
                case value
                when String, Array, Hash, Float, Integer, Fixnum, Bignum
                    msg = {
                        type: :push,
                        push: :status,
                        mod: mod_id,
                        stat: status_name,
                        val: value
                    }
                    send_with_id(msg)
                else
                    ::Libuv::Q.reject(@thread, 'unable to serialise status value')
                end
            end

            def restore
                msg = {
                    type: :restore
                }
                send_with_id(msg)
            end

            def expire_cache(sys_id)
                msg = {
                    type: :expire,
                    sys: sys_id
                }
                send_with_id(msg)
            end


            # -------------------------------------
            # Processing data from the remote node:
            # -------------------------------------

            def process(msg)
                case msg[:type].to_sym
                when :cmd
                    puts "\nexec #{msg[:mod]}.#{msg[:func]} -> as #{msg[:user] || 'anonymous'}"
                    exec(msg[:id], msg[:mod], msg[:func], Array(msg[:args]), msg[:user])
                when :stat
                    get_status(msg[:id], msg[:mod], msg[:stat])
                when :resp
                    puts "\nresp #{msg}"
                    response(msg)
                when :push
                    puts "\n#{msg[:push]} #{msg[:mod]}"
                    command(msg)
                when :restore
                    puts "\nServer requested we restore control"
                    begin
                        @ctrl.nodes[NodeId].slave_control_restored
                        send_resolution msg[:id], true
                    rescue => e
                        send_rejection msg[:id], e
                    end
                when :expire
                    sys = ControlSystem.find_by_id msg[:sys]
                    if sys
                        @ctrl.expire_cache sys, false
                        send_resolution msg[:id], true
                    else
                        send_rejection msg[:id], 'system not found in database'
                    end
                end
            end


            protected


            def next_id
                @count += 1
                ::Radix.convert(@count, B10, B65).freeze
            end

            # This is a response to a message we requested from the node
            def response(msg)
                request = @sent.delete msg[:id]

                if request
                    if msg[:reject]
                        # Rebuild the error and set the backtrace
                        klass = msg[:klass]
                        err = klass ? klass.constantize.new(msg[:reject]) : RuntimeError.new(msg[:reject])
                        err.set_backtrace(msg[:btrace]) if msg.has_key? :btrace
                        request.reject err
                    else
                        request.resolve msg[:resolve]
                        if msg[:was_object]
                            # TODO:: log a warning that the return value might not
                            # be what was expected
                        end
                    end
                else
                    # TODO:: log a warning as we can't find this request
                end
            end


            # This is a request from the remote node
            def exec(req_id, mod_id, func, args, user_id)
                mod = @ctrl.loaded? mod_id
                user = User.find_by_id(user_id) if user_id

                if mod
                    result = Core::RequestProxy.new(@thread, mod, user).method_missing(func, *args)
                    if result.is_a? ::Libuv::Q::Promise
                        result.then do |val|
                            send_resolution(req_id, val)
                        end
                        result.catch do |err|
                            send_rejection(req_id, err.message)
                        end
                    else
                        send_resolution(req_id, result)
                    end
                else
                    # reject the request
                    send_rejection(req_id, 'module not loaded')
                end
            end

            # This is a request from the remote node
            def get_status(req_id, mod_id, status)
                mod = @ctrl.loaded? mod_id

                if mod
                    val = mod.status[status.to_sym]
                    send_resolution(req_id, val)
                else
                    send_rejection(req_id, 'module not loaded')
                end
            end

            # This is a request that isn't looking for a response
            def command(msg)
                msg_type = msg[:push].to_sym

                case msg_type
                when :shutdown
                    # TODO:: shutdown the control server
                    # -- This will trigger the failover
                    # -- Good for performing updates with little downtime

                when :reload
                    dep = Dependency.find_by_id(msg[:dep])
                    if dep
                        result = @dep_man.load(dep, :force)
                        promise_response(msg[:id], result)
                    else
                        send_rejection(msg[:id], "dependency #{msg[:dep]} not found")
                    end

                when :load
                    result = @ctrl.update(msg[:mod], false)
                    promise_response(msg[:id], result)

                when :start, :stop
                    result = @ctrl.__send__(msg_type, msg[:mod], false)
                    promise_response(msg[:id], result)

                when :unload
                    result = @ctrl.unload(msg[:mod], false)
                    promise_response(msg[:id], result)

                when :status
                    mod_id = msg[:mod]
                    mod = @ctrl.loaded?(mod_id)

                    if mod
                        begin
                            # The false indicates "don't send this update back to the remote node"
                            mod.trak(msg[:stat].to_sym, msg[:val], false)
                            send_resolution(msg[:id], true)
                            puts "Received status #{msg[:stat]} = #{msg[:val]}"
                        rescue => e
                            send_rejection(msg[:id], e)
                        end
                    else
                        send_rejection(msg[:id], 'module not loaded')
                    end
                end
            end


            # ------------
            # IO Transport
            # ------------

            def send_with_id(msg, defer = @thread.defer)
                @thread.schedule do
                    begin
                        id = next_id
                        msg[:id] = id
                        @sent[id] = defer
                        output = ::JSON.generate(msg)
                        @tcp.write "\x02#{output}\x03"
                    rescue => e
                        @sent.delete id
                        defer.reject e
                    end
                end
                defer.promise
            end

            def send_direct(msg)
                output = ::JSON.generate(msg)
                @tcp.write "\x02#{output}\x03"
            end

            def promise_response(msg_id, promise)
                promise.then(proc {|success|
                    send_resolution msg_id, success
                }, proc { |failure|
                    send_rejection msg_id, failure
                })
            end

            # Reply to Requests
            def send_resolution(req_id, value)
                response = {
                    id: req_id,
                    type: :resp
                }

                # Don't send nil values (save on bytes)
                response[:resolve] = value if value

                output = nil
                begin
                    output = ::JSON.generate(response)
                rescue
                    response[:was_object] = true
                    response.delete(:resolve)

                    # Value probably couldn't be converted into a JSON object for transport...
                    output = ::JSON.generate(response)
                end

                @thread.schedule {
                    @tcp.write "\x02#{output}\x03"
                }
            end

            def send_rejection(req_id, msg)
                response = {
                    id: req_id,
                    type: :resp
                }

                if msg.is_a? Exception
                    response[:klass] = msg.class.name
                    response[:reject] = msg.message
                    response[:btrace] = msg.backtrace
                else
                    response[:reject] = msg
                end

                output = ::JSON.generate(response)

                @thread.schedule {
                    @tcp.write "\x02#{output}\x03"
                }
            end
        end
    end
end
