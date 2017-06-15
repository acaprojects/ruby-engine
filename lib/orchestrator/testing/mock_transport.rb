# frozen_string_literal: true

# NOTE:: include RSpec::Matchers

module Orchestrator::Testing; end
class Orchestrator::Testing::MockTransport
    def transmit(cmd)
        data = cmd[:data]

        if @config[:before_transmit]
            begin
                data = @config[:before_transmit].call(data, cmd)
            rescue => err
                @manager.logger.print_error(err, 'error in before_transmit callback')

                if @processor.queue.waiting == cmd
                    # Fail fast
                    @processor.thread.next_tick do
                        @processor.__send__(:resp_failure, err)
                    end
                else
                    cmd[:defer].reject(err)
                end

                # Don't try and send anything
                return
            end
        end

        @outgoing << data
        puts "TX: #{data.inspect}"
    end

    def receive(data)
        if @config[:before_buffering]
            begin
                data = @config[:before_buffering].call(data)
            rescue => err
                # We'll continue buffering and provide feedback as to the error
                @manager.logger.print_error(err, 'error in before_buffering callback')
            end
        end

        if @delaying
            @delaying << data
            result = @delaying.split(@config[:wait_ready], 2)
            if result.length > 1
                @delaying = nil
                rem = result[-1]

                @processor.connected
                @processor.buffer(rem) unless rem.empty?
            end
        else
            @processor.buffer(data)
        end
    end

    def check_outgoing(contains)
        index = @outgoing.index(contains)
        if index
            @outgoing = @outgoing[(index + 1)..-1]
            true
        else
            false
        end
    end


    # ===============
    # used in devices
    # ===============
    def initialize(manager, processor, _ = nil)
        @incomming = []
        @outgoing = []

        @manager = manager
        @processor = processor
        @config = @processor.config

        if @config[:wait_ready]
            @delaying = String.new
        else
            @processor.thread.next_tick do
                @processor.connected
            end
        end
    end

    attr_reader :delaying, :outgoing, :incomming

    def disconnect
        @processor.disconnected
        @incomming = []
        @outgoing = []
        @processor.connected
    end

    def terminate; end

    def force_offline
        @processor.disconnected
        @processor.queue.offline(@config[:clear_queue_on_disconnect])
        @incomming = []
        @outgoing = []
    end

    def force_online
        @processor.queue.online
        @processor.connected
    end


    # ================
    # used in services
    # ================
    def server
        self
    end

    def cookiejar
        self
    end

    def clear_cookies
        true
    end

    def middleware
        []
    end
end
