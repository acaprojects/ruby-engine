# frozen_string_literal: true

# NOTE:: include RSpec::Matchers
require 'orchestrator/testing/mock_transport'

module Orchestrator::Testing; end
class Orchestrator::Testing::DeviceManager < ::Orchestrator::Core::ModuleManager
    attr_reader :processor, :connection


    # Ensure remote isn't ever called
    def trak(name, value, remote = false)
        super(name, value, false)
    end


    def start_local(online = true)
        return false if not online
        return true if @processor

        @processor = ::Orchestrator::Device::Processor.new(self)
        super online

        @logger.level = :debug
        @connection = ::Orchestrator::Testing::MockTransport.new(self, @processor)

        @processor.transport = @connection
        true # for REST API
    end

    def stop_local
        super
        @processor.terminate if @processor
        @processor = nil
        @connection.terminate if @connection
        @connection = nil
    end

    def apply_config
        cfg = @klass.__default_config(@instance) if @klass.respond_to? :__default_config
        opts = @klass.__default_opts(@instance)  if @klass.respond_to? :__default_opts

        if @processor
            @processor.config = cfg
            @processor.send_options(opts)
        end
    rescue => e
        @logger.print_error(e, 'error applying config, driver may not function correctly')
    end

    def notify_connected
        if @instance.respond_to? :connected, true
            begin
                @instance.__send__(:connected)
            rescue => e
                @logger.print_error(e, 'error in module connected callback')
            end
        end
    end

    def notify_disconnected
        if @instance.respond_to? :disconnected, true
            begin
                @instance.__send__(:disconnected)
            rescue => e
                @logger.print_error(e, 'error in module disconnected callback')
            end
        end
    end

    def notify_received(data, resolve, command = nil)
        begin
            blk = command.nil? ? nil : command[:on_receive]
            if blk.respond_to? :call
                blk.call(data, resolve, command)
            elsif @instance.respond_to? :received, true
                @instance.__send__(:received, data, resolve, command)
            else
                @logger.warn('no received function provided')
                :abort
            end
        rescue => e
            @logger.print_error(e, 'error in received callback')
            return :abort
        end
    end
end
