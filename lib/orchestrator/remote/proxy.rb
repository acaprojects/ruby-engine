# frozen_string_literal: true

require 'radix/base'

module Orchestrator
    module Remote
        Request = Struct.new(:type, :ref, :value, :args, :user, :id)

        class Proxy
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
                msg = Request.new :cmd, mod_id, func, args, user_id
                send_with_id(msg)
            end

            def status(mod_id, status_name)
                msg = Request.new :stat, mod_id, status_name
                send_with_id(msg)
            end

            def shutdown
                msg = Request.new :push, nil, :shutdown
                send_direct(msg)
            end

            # TODO:: Expire System Cache
            # TODO:: Reload module, system, dependency, zone (settings update)
            # ------> Might also need to pass the settings down the wire to avoid race conditions

            def reload(dep_id)
                msg = Request.new :push, dep_id, :reload
                send_with_id(msg)
            end

            [:load, :start, :stop, :unload].each do |cmd|
                define_method cmd do |mod_id|
                    msg = Request.new :push, mod_id, cmd
                    send_with_id(msg)
                end
            end

            def set_status(mod_id, status_name, value)
                msg = Request.new :push, mod_id, :status, [status_name, value]
                send_with_id(msg)
            end

            def restore
                send_with_id(Request.new :restore)
            end

            def expire_cache(sys_id, no_update = false)
                msg = Request.new :expire, sys_id, !!no_update
                send_with_id(msg)
            end

            def clear_cache
                send_with_id(Request.new :clear)
            end


            # -------------------------------------
            # Processing data from the remote node:
            # -------------------------------------

            def process(msg)
                case msg.type
                when :cmd
                    puts "\nexec #{msg.ref}.#{msg.value} -> as #{msg.user || 'anonymous'}"
                    exec(msg.id, msg.ref, msg.value, Array(msg.args), msg.user)
                when :stat
                    get_status(msg.id, msg.ref, msg.value)
                when :resolve
                    resolve(msg)
                when :reject
                    reject(msg)
                when :push
                    puts "\n#{msg.value} #{msg.ref}"
                    command(msg)
                when :restore
                    puts "\nServer requested we restore control"
                    begin
                        @ctrl.nodes[NodeId].slave_control_restored
                        send_resolution msg.id, true
                    rescue => e
                        send_rejection msg.id, e
                    end
                when :expire
                    @ctrl.expire_cache msg.ref, false, no_update: msg.value
                    send_resolution msg.id, true
                when :clear
                    ::Orchestrator::System.clear_cache
                    send_resolution msg.id, true
                end
            end


            protected


            def next_id
                @count += 1
                @count
            end

            # This is a response to a message we requested from the node
            def resolve(msg)
                puts "resolution #{msg.id}: #{msg.value}"

                request = @sent.delete msg.id
                if request
                    request.resolve msg.value
                else
                    # TODO:: log a warning as we can't find this request
                end
            end

            def reject(msg)
                puts "rejection #{msg.id}: #{msg.value}"

                request = @sent.delete msg.id
                if request
                    request.reject msg.value
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
                msg_type = msg.value
                case msg_type
                when :shutdown
                    # TODO:: shutdown the control server
                    # -- This will trigger the failover
                    # -- Good for performing updates with little downtime

                when :reload
                    dep = Dependency.find_by_id(msg.ref)
                    if dep
                        result = @dep_man.load(dep, :force)
                        promise_response(msg.id, result)
                    else
                        send_rejection(msg.id, "dependency #{msg.ref} not found")
                    end

                when :load
                    result = @ctrl.update(msg.ref, false)
                    promise_response(msg.id, result)

                when :start, :stop
                    result = @ctrl.__send__(msg_type, msg.ref, false)
                    promise_response(msg.id, result)

                when :unload
                    result = @ctrl.unload(msg.ref, false)
                    promise_response(msg.id, result)

                when :status
                    mod_id = msg.ref
                    mod = @ctrl.loaded?(mod_id)

                    if mod
                        begin
                            status_name, value = msg.args

                            # The false indicates "don't send this update back to the remote node"
                            mod.trak(status_name, value, false)
                            send_resolution(msg.id, true)
                            puts "Received status #{status_name} = #{value}"
                        rescue => e
                            send_rejection(msg.id, e)
                        end
                    else
                        send_rejection(msg.id, 'module not loaded')
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
                        msg.id = id
                        @sent[id] = defer
                        output = Marshal.dump(msg)
                        @tcp.write "#{output}\x00\x00\x00\x03"
                    rescue => e
                        @sent.delete id
                        defer.reject e
                    end
                end
                defer.promise
            end

            def send_direct(msg)
                output = Marshal.dump(msg)
                @tcp.write "#{output}\x00\x00\x00\x03"
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
                response = Request.new :resolve
                response.id = req_id
                response.value = value
                output = Marshal.dump(response)

                @thread.schedule {
                    @tcp.write "#{output}\x00\x00\x00\x03"
                }
            end

            def send_rejection(req_id, reason)
                response = Request.new :reject
                response.id = req_id
                response.value = reason
                output = Marshal.dump(response)

                @thread.schedule {
                    @tcp.write "#{output}\x00\x00\x00\x03"
                }
            end
        end
    end
end
