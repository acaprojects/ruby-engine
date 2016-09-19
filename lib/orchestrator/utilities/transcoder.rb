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
            output = []
            data.scan(/.{2}/) { |byte| output << byte.hex}
            output.pack('c*')
        end

        # Converts a binary string into a hex encoded string
        #
        # @param data [String] a binary string
        # @return [String]
        def byte_to_hex(data)
            data = array_to_str(data) if data.is_a? Array

            output = String.new
            data.each_byte { |c|
                s = c.to_s(16)
                s.prepend('0') if s.length % 2 > 0
                output << s
            }
            return output
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


        # Makes the functions private when included
        module_function :hex_to_byte
        module_function :byte_to_hex
        module_function :str_to_array
        module_function :array_to_str
    end
end
