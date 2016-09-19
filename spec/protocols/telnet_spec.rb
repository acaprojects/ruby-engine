# encoding: ASCII-8BIT
# frozen_string_literal: true

require 'rails'
require 'protocols/telnet'


describe "telnet protocol helper" do
    before :each do
        @log = []
        @telnet = Protocols::Telnet.new do |cmd|
            # Write callback
            @log << cmd
        end
    end

    it "should buffer input and process any telnet commands" do
        @log << @telnet.buffer("\xFF\xFD\x18\xFF\xFD \xFF\xFD#\xFF\xFD'hello there")
        expect(@log).to eq(["\xFF\xFC\x18", "\xFF\xFC ", "\xFF\xFC#", "\xFF\xFC'", "hello there"])
    end

    it "should append the appropriate line endings to requests" do
        @telnet.buffer("\xFF\xFD\x18\xFF\xFD \xFF\xFD#\xFF\xFD'")
        @log.clear

        @log << @telnet.prepare("hello")
        expect(@log).to eq(["hello\r\n"])
    end
end
