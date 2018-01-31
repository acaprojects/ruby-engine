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
        @driver = ::WebSocket::Driver::Client.new(self, options)

        @driver.on :close do |event|
            @mod.__send__(:disconnect)
            @mod.on_close(event) if @mod.respond_to?(:on_close)
        end

        @driver.on :message do |event|
            @mod.on_message(event.data)
        end

        @driver.on :error do |event|
            @mod.__send__(:disconnect)

            if @mod.respond_to?(:on_error)
                @mod.on_error(event)
            elsif @mod.respond_to?(:on_close)
                @mod.on_close(event)
            end
        end

        @driver.on :open do |event|
            @mod.on_open(event) if @mod.respond_to?(:on_open)
        end

        @driver.start
    end

    def write(string)
        @mod.__send__(:send, string, wait: false)
    end

    # Write some text to the websocket connection
    #
    # @param string [String] a string of data to be sent to the far end
    def text(string)
        @driver.text(string.to_s)
    end

    # Write some binary data to the websocket connection
    #
    # @param array [Array] an array of bytes to be sent to the far end
    def binary(array)
        @driver.binary(array.to_a)
    end
end
