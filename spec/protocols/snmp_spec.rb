# encoding: UTF-8
# frozen_string_literal: true

require 'libuv'
require 'protocols/snmp'

describe "SNMP protocol helper" do
    class SnmpTest
        attr_reader :data

        def send(data)
            @request = reactor.defer
            @data = data
            @request.promise
        end

        def receive(data)
            @request.resolve(data)
        end
    end

    before :each do
        @mod = SnmpTest.new
        @proxy = Protocols::Snmp.new(@mod)
        @client = NETSNMP::Client.new(proxy: @proxy, version: "2c", community: "public")
    end

    after :each do
        @client.close
    end

    it "should buffer input and process SNMP packets" do
        result = nil
        reactor.run { |reactor|
            reactor.next_tick do
                # Manipulate data here
                magic = @mod.data[17..20].force_encoding('UTF-8')
                data  = "0;\x02\x01\x01\x04\x06public\xA2.\x02\x04#{magic}" + 
                        "\x02\x01\x00\x02\x01\x000 0\x1E\x06\b+\x06\x01\x02\x01\x01\x01\x00\x04\x12Device description"
                @mod.receive(data)
            end
            result = @client.get(oid: "1.3.6.1.2.1.1.1.0")
            reactor.stop
        }

        expect(result).to eq('Device description')
    end
end
