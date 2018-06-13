# frozen_string_literal: true

require 'rails'
require 'orchestrator'

describe Orchestrator::Transcoder do

    describe '#hex_to_byte' do
        it 'should be able to convert hex strings into binary strings' do
            result = Orchestrator::Transcoder.hex_to_byte('0x00112233')
            expect(result).to eq("\x00\x11\x22\x33")

            result = Orchestrator::Transcoder.hex_to_byte('\x00\x11\x22\x33')
            expect(result).to eq("\x00\x11\x22\x33")

            result = Orchestrator::Transcoder.hex_to_byte('h00h11h22h33')
            expect(result).to eq("\x00\x11\x22\x33")

            result = Orchestrator::Transcoder.hex_to_byte('00h 11h 22h 33h')
            expect(result).to eq("\x00\x11\x22\x33")

            result = Orchestrator::Transcoder.hex_to_byte('00 11 22 33')
            expect(result).to eq("\x00\x11\x22\x33")
        end

        it 'should deal will hex that is not byte aligned' do
            result = Orchestrator::Transcoder.hex_to_byte('0x0011223')
            expect(result).to eq("\x00\x01\x12\x23")

            result = Orchestrator::Transcoder.hex_to_byte('\x00\x11\x22\x3')
            expect(result).to eq("\x00\x01\x12\x23")

            result = Orchestrator::Transcoder.hex_to_byte('h00h11h22h3')
            expect(result).to eq("\x00\x01\x12\x23")

            result = Orchestrator::Transcoder.hex_to_byte('00h 11h 22h 3h')
            expect(result).to eq("\x00\x01\x12\x23")

            result = Orchestrator::Transcoder.hex_to_byte('00 11 22 3')
            expect(result).to eq("\x00\x01\x12\x23")
        end
    end

    describe '#byte_to_hex' do
        it 'should be able to convert binary strings into hex strings' do
            result = Orchestrator::Transcoder.byte_to_hex("\x00\x11\x22\x33")
            expect(result).to eq("00112233")
        end

        it 'should be able to convert an array of bytes into hex strings' do
            result = Orchestrator::Transcoder.byte_to_hex([0x00, 0x11, 0x22, 0x33])
            expect(result).to eq("00112233")
        end
    end

    describe '#int_to_array' do
        it 'should be able to convert positive integers into a byte array' do
            result = Orchestrator::Transcoder.int_to_array(400)
            expect(result).to eq([1, 144])

            result = Orchestrator::Transcoder.int_to_array(400, bytes: 4)
            expect(result).to eq([0, 0, 1, 144])
        end

        it 'should be able to convert negative integers into a byte array' do
            result = Orchestrator::Transcoder.int_to_array(-400, bytes: 4)
            expect(result).to eq([255, 255, 254, 112])

            # Check edge case where first byte overflows on 2s compliment
            result = Orchestrator::Transcoder.int_to_array(-256, bytes: 3)
            expect(result).to eq([255, 255, 0])
        end
    end

end
