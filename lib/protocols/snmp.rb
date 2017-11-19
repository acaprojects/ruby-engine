# frozen_string_literal: true

require 'netsnmp'

module Protocols; end

# A simple proxy object for netsnmp
# See https://github.com/swisscom/ruby-netsnmp
class Protocols::Snmp
    def initialize(driver)
        @driver = driver
    end

    def send(payload)
        @driver.send(payload).value
    end
end
