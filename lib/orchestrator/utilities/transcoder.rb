# encoding: ASCII-8BIT
# frozen_string_literal: true

module Orchestrator
    module Transcoder
        # Converts a hex encoded string into a binary string
        #
        # @param data [String] a hex encoded string
        # @return [String]
        def hex_to_byte(data)
            # Removes invalid characters
            data = data.gsub(/(0x|[^0-9A-Fa-f])*/, "")

            # Ensure we have an even number of characters
            data.prepend('0') if data.length % 2 > 0

            # Breaks string into an array of characters
            [data].pack('H*')
        end

        # Converts a binary string into a hex encoded string
        #
        # @param data [String] a binary string
        # @return [String]
        def byte_to_hex(data)
            data = array_to_str(data) if data.is_a? Array
            data.unpack('H*')[0]
        end

        # Converts a string into an array of bytes
        #
        # @param data [String] data to be converted to bytes
        # @return [Array]
        def str_to_array(data)
            return data if data.is_a? Array
            data.bytes
        end

        # Converts a byte array into a binary string
        #
        # @param data [Array] an array of bytes
        # @return [String]
        def array_to_str(data)
            return data if data.is_a? String
            data.pack('c*')
        end

        # Converts an integer into a byte array (reverse to change endianness)
        #
        # @param integer [Integer]
        # @return [Array]
        def int_to_array(integer, bytes: nil, pad: 0)
            x = integer.to_i

            # ensure positive x
            negative = false
            if x < 0
                negative = true
                x = x * -1
            end

            # Grab the positive bytes
            result = []
            until x == 0
                result.unshift(x & 0xff)
                x = x >> 8
            end

            if negative && bytes
                # We can calculate the 2s compliment if we know the size of the structure
                binary = result.map {|n| (n ^ 0xff).to_s(2).rjust(8, '0') }.join('').to_i(2) + 1
                return int_to_array(binary, bytes: bytes, pad: 0xff)
            elsif bytes
                # Pad the result
                padding = bytes - result.length
                result = [pad] * padding + result if padding > 0
            end

            result
        end

        # Makes the functions private when included
        module_function :hex_to_byte
        module_function :byte_to_hex
        module_function :str_to_array
        module_function :array_to_str
        module_function :int_to_array
    end
end
