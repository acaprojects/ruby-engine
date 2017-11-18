# frozen_string_literal: true

require 'algorithms'
require 'bisect'

module Orchestrator
    module Device
        class CommandQueue


            OFFLINE_MSG = Error::CommandCanceled.new 'command canceled as module went offline'
            attr_reader :state
            attr_accessor :waiting


            def initialize(reactor, default_callback = nil)
                @reactor = reactor
                @default = default_callback
                @callback = nil

                @named_commands = {
                    # name: [[priority list], command]
                    # where command may be nil
                }
                @comparison = method(:comparison)
                @pending_commands = Containers::Heap.new(&@comparison)

                @state = :online    # online / offline
                @perform_pop = method(:perform_pop)
            end

            # Provides a callback to pass the next command to.
            # The callback is always perfomed in the next tick so that
            # 
            def pop(blk = @default)
                return if @waiting
                @callback = blk
                @reactor.next_tick &@perform_pop if blk
            end

            # Dump the current list of commands in order
            def to_a
                finished = Set.new
                cmds = []
                while @pending_commands.length > 0
                    cmds << @pending_commands.pop
                end
                cmds.collect { |next_cmd|
                    if next_cmd.is_a?(Symbol)
                        if finished.include?(next_cmd)
                            nil
                        else
                            @named_commands[next_cmd][1]
                        end
                    else
                        next_cmd
                    end
                }.reject { |cmd| cmd.nil? }
            end

            # Adds a command to the queue and performs a pop if there
            # is a callback waiting and this is the only item in the
            # queue. (i.e. a pop is not already in progress)
            def push(command, priority)
                # Ignore non-named commands when we are offline
                if @state == :offline && command[:name].nil?
                    return
                end

                if command[:name]
                    name = command[:name].to_sym

                    current = @named_commands[name] ||= [[], nil]

                    # Chain the promises if the named command is already in the queue
                    cmd = current[1]
                    cmd[:defer].resolve(command[:defer].promise) if cmd

                    
                    current[1] = command   # replace the old command
                    priors = current[0]

                    # Only add commands of higher priority to the queue
                    if priors.empty? || priors[-1] < priority
                        priors << priority
                        queue_push(@pending_commands, name, priority)
                    end
                else
                    queue_push(@pending_commands, command, priority)
                end

                if @callback && length == 1
                    @reactor.next_tick &@perform_pop
                end
            end

            def length
                @pending_commands.size
            end


            # If offline we'll only maintain named commands
            # all non-named commands are removed from the queue.
            # This prevents the queue from becoming large when the queue
            # may not be reducing in size
            def online
                @state = :online
            end

            def online?
                @state == :online
            end

            def offline(clear = false)
                @state = :offline

                if clear
                    cancel_all(OFFLINE_MSG)
                else
                    # Keep named commands
                    new_queue = Containers::Heap.new(&@comparison)

                    while length > 0
                        cmd = @pending_commands.pop
                        if cmd.is_a? Symbol
                            res = @named_commands[cmd][0]
                            pri = res.shift
                            res << pri
                            queue_push(new_queue, cmd, pri)
                        else
                            cmd[:defer].reject(OFFLINE_MSG)
                        end
                    end
                    @pending_commands = new_queue
                end
            end

            # Removes all the commands from the queue and provides
            # the promises a rejection message
            def cancel_all(msg)
                while length > 0
                    cmd = @pending_commands.pop
                    if cmd.is_a? Symbol
                        res = @named_commands[cmd]
                        if res
                            res[1][:defer].reject(msg)
                            @named_commands.delete(cmd)
                        end
                    else
                        cmd[:defer].reject(msg)
                    end
                end
            ensure
                @named_commands = {}
                @pending_commands = Containers::Heap.new(&@comparison)
                pop nil
            end


            protected


            # If there is a callback waiting and a command in the queue
            # Then we want to remove the command and pass it to the callback
            class PerformRetry < Error; end
            DoRetry = PerformRetry.new 'no problem'
            def perform_pop
                if @callback && length > 0 && !@waiting
                    next_cmd = @pending_commands.pop

                    if next_cmd.is_a? Symbol # (named command)
                        result = @named_commands[next_cmd]
                        result[0].shift
                        cmd = result[1]
                        if cmd.nil?
                            raise DoRetry
                        else
                            result[1] = nil
                        end
                    else
                        cmd = next_cmd
                    end

                    # Wait for the next call to pop
                    callback = @callback
                    @callback = nil
                    @waiting = cmd

                    callback.call cmd
                end
            rescue PerformRetry => e
                retry
            end


            # Queue related methods
            # This ensures that the highest priorities (largest values)
            # Are processed first, if they have the same priority then they are
            # processed in the order that the commands were queued
            #
            # See: http://www.rubydoc.info/github/kanwei/algorithms/Containers/MaxHeap#initialize-instance_method
            def comparison(x, y)
                if x[0] == y[0]
                    x[1] < y[1]
                else
                    (x[0] <=> y[0]) == 1
                end
            end

            def queue_push(queue, obj, pri)
                pri = [pri, Time.now.to_f]
                queue.push(pri, obj)
            end
        end
    end
end
