# frozen_string_literal: true
# encoding: ASCII-8BIT

require 'set'

# Transport -> connection (make break etc)
# * attach connected, disconnected callbacks
# * udp, makebreak and tcp transports
# Manager + CommandProcessor + Transport

module Orchestrator
    module Device
        class Processor
            include ::Orchestrator::Transcoder


            # Any command that waits:
            # send('power on?').then( execute after command complete )
            # Named commands mean the promise may never resolve
            # Totally replaces emit as we don't care and makes cross module request super easy
            # -- non-wait commands resolve after they have been written to the socket!!


            SEND_DEFAULTS = {
                wait: true,                 # wait for a response before continuing with sends
                delay: 0,                   # make sure sends are separated by at least this (in milliseconds)
                delay_on_receive: 0,        # delay the next send by this (milliseconds) after a receive
                max_waits: 3,               # number of times we will ignore valid tokens before retry
                retries: 2,                 # Retry attempts before we give up on the command
                hex_string: false,          # Does the input need conversion
                timeout: 5000,              # Time we will wait for a response
                priority: 50,               # Priority of a send
                force_disconnect: false     # Will disconnect once a response has been buffered

                # Other options include:
                # * emit callback to occur once command complete (may be discarded if a named command)
                # * on_receive (alternative to received function)
                # * clear_queue (clear further commands once this has run)
                # * disconnect: true (disconnect once the command has finally been processed)
            }

            CONFIG_DEFAULTS = {
                tokenize: false,    # If replaced with a callback can define custom tokenizers
                size_limit: 524288, # 512kb buffer max
                clear_queue_on_disconnect: false,
                flush_buffer_on_disconnect: false,
                priority_bonus: 20,  # give commands bonus priority under certain conditions
                update_status: true, # auto update connected status?
                thrashing_threshold: 1500, # min milliseconds between connection retries
                wait_ready_timeout: 10000  # time to wait for a remote system to accept commands

                # Other options include:
                # * inactivity_timeout (used with make and break)
                # * delimiter (string or regex to match message end)
                # * indicator (string or regex to match message start)
                # * verbose (throw errors or silently recover)
                # * wait_ready (wait for some signal before signaling connected)
                # * encoding (BINARY) (force encoding on incoming data)
                # * before_transmit  (callback for last min data modifications)
                # * before_buffering (callback for pre-buffering manipulation)
            }


            SUCCESS = Set.new([true, :success, :abort, nil, :ignore])
            FAILURE = Set.new([false, :retry, :failed, :fail])
            DUMMY_RESOLVER = proc {}
            TERMINATE_MSG = Error::CommandCanceled.new 'command canceled due to module shutdown'
            UNNAMED = 'unnamed'


            attr_reader :config, :queue, :thread, :defaults
            attr_accessor :transport

            # For statistics only
            attr_reader :last_sent_at, :last_receive_at, :timeout


            # init -> mod.load -> post_init
            # So config can be set in on_load if desired
            def initialize(man)
                @man = man

                @thread = @man.thread
                @logger = @man.logger
                @defaults = SEND_DEFAULTS.dup
                @config = CONFIG_DEFAULTS.dup

                @queue = CommandQueue.new(@thread, proc { |c| send_next(c) })
                @responses = []
                @wait = false
                @connected = false
                @checking = Mutex.new
                @bonus = 0

                @last_sent_at = 0
                @last_receive_at = 0

                # Used to indicate when we can start the next response processing
                @head = ::Libuv::Q::ResolvedPromise.new(@thread, true)
                @tail = ::Libuv::Q::ResolvedPromise.new(@thread, true)

                # Method variables
                @resolver = proc { |resp| @thread.schedule { resolve_callback(resp) } }

                @resp_success = proc { |result| @thread.next_tick { resp_success(result) } }
                @resp_failure = proc { |reason| @thread.next_tick { resp_failure(reason) } }
            end

            ##
            # Helper functions ------------------
            def send_options(options)
                @defaults.merge!(options) if options
            end

            def config=(options)
                if options
                    @config.merge!(options)
                    # use tokenize to signal a buffer update
                    new_buffer if options.include?(:tokenize)
                end
            end

            #
            # Public interface
            def queue_command(options)
                # Make sure we are sending appropriately formatted data
                raw = options[:data]

                if raw.is_a?(Array)
                    options[:data] = array_to_str(raw)
                elsif options[:hex_string] == true
                    options[:data] = hex_to_byte(raw)
                end

                data = options[:data]
                options[:retries] = 0 if options[:wait] == false

                if options[:name].is_a? String
                    options[:name] = options[:name].to_sym
                end

                # merge in the defaults
                options = @defaults.merge(options)

                if @transport
                    if @transport.delaying
                        @transport.transmit(options)
                    else
                        @queue.push(options, options[:priority] + @bonus)
                    end

                    @queue.pop if @queue.length > 0
                else
                    @logger.warn 'command sent before transport ready. This may lead to undesirable behaviour'
                    @queue.push(options, options[:priority] + @bonus)
                end
            rescue => e
                options[:defer].reject(e)
                @logger.print_error(e, 'error queuing command')
            end

            ##
            # Callbacks -------------------------
            def connected
                @connected = true
                new_buffer
                @man.notify_connected
                @man.trak(:connected, true) if @config[:update_status]
            end

            def connected?
                @connected == true
            end

            def disconnected
                @connected = false
                @man.notify_disconnected
                @man.trak(:connected, false) if @config[:update_status]
                if @buffer && @config[:flush_buffer_on_disconnect]
                    check_data(@buffer.flush)
                end
                @buffer = nil

                resp_failure(:disconnected) if @queue.waiting
            end

            def soft_disconnect
                if @queue.waiting
                    resp_failure(:disconnected)
                elsif @queue.length > 0
                    @queue.pop
                end
            end

            def buffer_size
                if @buffer&.respond_to?(:bytesize)
                    @buffer.bytesize
                else
                    0
                end
            end

            def buffer(data)
                @last_receive_at = @thread.now

                if @buffer
                    begin
                        @responses.concat @buffer.extract(data)
                    rescue => e
                        @logger.print_error(e, 'error tokenizing data. Clearing buffer..')
                        new_buffer
                    end
                else
                    # tokenizing buffer above will enforce encoding
                    data.force_encoding(@config[:encoding]) if @config[:encoding]
                    @responses << data
                end

                # if we are waiting we don't want to process this data just yet
                check_next if !@wait
            end

            def terminate
                @thread.schedule do
                    if @queue.waiting
                        @queue.waiting[:defer].reject(TERMINATE_MSG)
                        @queue.waiting = nil
                    end
                    @queue.cancel_all(TERMINATE_MSG)
                end
            end

            # This keeps the response processing in lock step
            def check_next
                return if @checking.locked? || @responses.length <= 0
                @checking.synchronize {
                    loop do
                        check_data(@responses.shift)
                        break if @wait || @responses.length == 0
                    end
                }
            end


            protected


            def new_buffer
                tokenize = @config[:tokenize]
                if tokenize
                    if tokenize.respond_to? :call
                        @buffer = tokenize.call
                    else
                        @buffer = ::UV::BufferedTokenizer.new(@config)
                    end
                elsif @buffer
                    # remove the buffer if none
                    @buffer = nil
                end
            end

            # Check transport response data
            def check_data(data)
                resp = nil

                # Provide commands with a bonus in this section
                @bonus = @config[:priority_bonus]

                begin
                    cmd = @queue.waiting
                    if cmd
                        @wait = true
                        @defer = @thread.defer
                        @defer.promise.then @resp_success, @resp_failure

                        # Disconnect before processing the response
                        transport.disconnect if cmd[:force_disconnect]

                        # Send response, early resolver and command
                        resp = @man.notify_received(data, @resolver, cmd)
                    else
                        resp = @man.notify_received(data, DUMMY_RESOLVER, nil)
                        # Don't need to trigger Queue next here as we are not waiting on anything
                    end
                rescue => e
                    # NOTE:: This error should never be called
                    @logger.print_error(e, 'error processing response data')
                    @defer.reject :abort if @defer
                ensure
                    @bonus = 0
                end

                # Check if response is a success or failure
                resolve_callback(resp) unless resp == :async
            end

            def resolve_callback(resp)
                if @defer
                    if FAILURE.include? resp
                        @defer.reject resp
                    else
                        @defer.resolve resp
                    end
                    @defer = nil
                end
            end

            def resp_failure(result_raw)
                if @queue.waiting
                    begin
                        result = result_raw.is_a?(Integer) ? :timeout : result_raw
                        cmd = @queue.waiting
                        debug = String.new("with #{result}: <#{cmd[:name] || UNNAMED}> ")
                        if cmd[:data]
                            debug << "#{cmd[:data].inspect}"
                        else
                            debug << cmd[:path]
                        end
                        @logger.debug "command failed #{debug}"

                        if cmd[:retries] == 0
                            err = Error::CommandFailure.new "command aborted #{debug}"
                            cmd[:defer].reject(err)
                            @logger.warn err.message
                        else
                            cmd[:retries] -= 1
                            cmd[:wait_count] = 0      # reset our ignore count
                            @queue.push(cmd, cmd[:priority] + @config[:priority_bonus])
                        end

                        transport.disconnect if cmd[:disconnect]
                    rescue => e
                        # Prevent the queue from ever pausing - this should never be called
                        @logger.print_error(e, 'error handling request failure')
                    end
                end

                clear_timers

                @wait = false
                @queue.waiting = nil
                check_next                    # Process already received
                @queue.pop if @connected    # Then send a new command
            end

            # We only care about queued commands here
            # Promises resolve on the next tick so processing
            #  is guaranteed to have completed
            # Check for queue wait as we may have gone offline
            def resp_success(result)
                if @queue.waiting && result && result != :ignore
                    if result == :abort
                        cmd = @queue.waiting
                        err = Error::CommandFailure.new "module aborted command with #{result}: <#{cmd[:name] || UNNAMED}> #{(cmd[:data] || cmd[:path]).inspect}"
                        @queue.waiting[:defer].reject(err)
                    else
                        @queue.waiting[:defer].resolve(result)
                        call_emit @queue.waiting
                    end

                    clear_timers

                    @wait = false
                    @queue.waiting = nil
                    check_next    # Process pending

                    if cmd[:disconnect]
                        transport.disconnect
                        # Send the next command
                        @thread.next_tick { @queue.pop }
                    else
                        @queue.pop    # Send the next command
                    end

                    # Else it must have been a nil or :ignore
                elsif @queue.waiting
                    cmd = @queue.waiting
                    cmd[:wait_count] ||= 0
                    cmd[:wait_count] += 1
                    if cmd[:wait_count] > cmd[:max_waits]
                        resp_failure(:max_waits_exceeded)
                    else
                        @wait = false
                        check_next
                    end

                else  # ensure consistent state (offline event may have occurred)
                    clear_timers

                    @wait = false
                    check_next
                end
            end

            # If a callback was in place for the current
            def call_emit(cmd)
                callback = cmd[:emit]
                if callback.respond_to? :call
                    @thread.next_tick do
                        begin
                            callback.call
                        rescue => e
                            @logger.print_error(e, 'error in emit callback')
                        end
                    end
                end
            end


            # Callback for queued commands
            def send_next(command)
                # Check for any required delays between sends
                if command[:delay] > 0
                    gap = @last_sent_at + command[:delay] - @thread.now
                    if gap > 0
                        defer = @thread.defer
                        sched = schedule.in(gap) do
                            defer.resolve(process_send(command))
                        end
                        # in case of shutdown we need to resolve this promise
                        sched.catch do
                            defer.reject(:shutdown)
                        end
                        defer.promise
                    else
                        process_send(command)
                    end
                else
                    process_send(command)
                end
            end

            def process_send(command)
                # delay on receive
                if command[:delay_on_receive] > 0
                    gap = @last_receive_at + command[:delay_on_receive] - @thread.now

                    if gap > 0
                        defer = @thread.defer

                        sched = schedule.in(gap) do
                            defer.resolve(process_send(command))
                        end
                        # in case of shutdown we need to resolve this promise
                        sched.catch do
                            defer.reject(:shutdown)
                        end
                        defer.promise
                    else
                        transport_send(command)
                    end
                else
                    transport_send(command)
                end
            end

            def transport_send(command)
                @transport.transmit(command)
                @last_sent_at = @thread.now

                if command[:wait]
                    # Set up timers for command timeout
                    @timeout = schedule.in(command[:timeout], &@resp_failure)
                else
                    # resolve the send promise early as we are not waiting for the response
                    command[:defer].resolve(:no_wait)
                    call_emit command   # the command has been sent

                    # move the queue forward
                    @wait = false
                    @queue.waiting = nil
                    check_next                  # Process already received
                    @queue.pop if @connected    # Then send a new command
                end

                # Useful for emergency stops etc
                if command[:clear_queue]
                    @queue.cancel_all("Command #{command[:name]} cleared the queue")
                end

                nil # ensure promise chain is not propagated
            end

            def clear_timers
                @timeout.cancel if @timeout
                @timeout = nil
            end

            def schedule
                @schedule ||= @man.get_scheduler
            end
        end
    end
end
