# encoding: ASCII-8BIT
# frozen_string_literal: true

require 'websocket/driver'
require 'forwardable'

module Protocols; end

class Protocols::Websocket
    extend ::Forwardable
    def_delegators :@driver, :start, :ping, :protocol, :ready_state
    def_delegators :@driver, :state, :close, :status, :headers

    attr_reader :url

    def initialize(driver, url, **options)
        @url = url
        @mod = driver
        @send = callback
        @ready = false
        @driver = ::WebSocket::Driver::Client.new(self, options)

        @driver.on :close do |event|
            @ready = false
            @mod.__send__(:disconnect)
            @mod.on_close(event) if @mod.respond_to?(:on_close)
        end

        @driver.on :message do |event|
            @mod.on_message(event.data)
        end

        @driver.on :ping do |event|
            @mod.on_ping(event.data) if @mod.respond_to?(:on_ping)
        end

        @driver.on :pong do |event|
            @mod.on_pong(event.data) if @mod.respond_to?(:on_pong)
        end

        @driver.on :error do |event|
            @ready = false
            @mod.__send__(:disconnect)
            @mod.on_error(event) if @mod.respond_to?(:on_error)
        end

        @driver.on :open do |event|
            @ready = true
            @mod.on_open(event) if @mod.respond_to?(:on_open)
        end

        @driver.start
    end

    def write(string)
        @mod.__send__(:send, string, wait: false)
    end

    def parse(data)
        begin
            @driver.parse data
        rescue Exception => e
            @mod.__send__(:disconnect)
            raise e
        end
    end

    # Write some text to the websocket connection
    #
    # @param string [String] a string of data to be sent to the far end
    def text(string)
        raise "websocket not ready!" unless @ready
        @driver.text(string.to_s)
    end

    # Write some binary data to the websocket connection
    #
    # @param array [Array] an array of bytes to be sent to the far end
    def binary(array)
        raise "websocket not ready!" unless @ready
        @driver.binary(array.to_a)
    end
end
