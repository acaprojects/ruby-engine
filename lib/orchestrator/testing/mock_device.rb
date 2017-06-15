# frozen_string_literal: true


require 'rspec/expectations'
require 'orchestrator/testing/mock_transport'
require 'orchestrator/testing/device_manager'


module Orchestrator::Testing
    def self.mock_device(klass_name, **config, &block)
        role = :device

        reactor.run do |reactor|
            role = role.to_sym
            klass = ::Orchestrator::DependencyManager.load(klass_name.to_s, role)

            if klass.respond_to? :__discovery_details
                dis = ::Orchestrator::Discovery.new(klass.__discovery_details)

                if dis.role && role.to_s != dis.role
                    puts "WARN: role mismatch. Test requested #{role} and module defined #{dis.role}"
                end

                dep = ::Orchestrator::Dependency.new
                dep.name = dis.name
                dep.role = role
                dep.description = dis.description
                dep.default = dis.default
                dep.class_name = dis.class_name
                dep.module_name = dis.module_name
                dep.settings = dis.settings

                mod = ::Orchestrator::Module.new
                mod.dependency = dep
                mod.role = dep.role
                mod.port = config[:port] || dep.default
                mod.settings = config[:settings] || dep.settings
            else
                puts 'WARN: module is lacking discovery information'

                dep = ::Orchestrator::Dependency.new
                dep.name = config[:name] || 'unnamed device'
                dep.role = role
                dep.class_name = klass_name.to_s
                dep.module_name = 'Testing' || config[:module_name]

                mod = ::Orchestrator::Module.new
                mod.dependency = dep
                mod.role = dep.role
                mod.port = config[:port] || 80
                mod.settings = config[:settings]
            end

            mod.uri = config[:uri] || 'http://localhost'
            mod.ip = config[:ip] || '192.168.0.1'
            mod.id = 'mod-testing'

            begin
                md = MockDevice.new(role, klass, mod, reactor)
                puts 'INFO: Mock module loaded. Starting test.'
                md.wait_tick
                md.instance_exec(&block)
                md.wait_tick
                puts "\n------Final State------"
                md.print_queues
                puts "-----------------------\n\n"
                puts 'Tests completed without error.'
            rescue => e
                puts "ERROR: #{e.message}\n#{e.backtrace.join("\n")}"
            ensure
                reactor.next_tick do
                    reactor.stop
                end
            end
        end
    end
end

class Orchestrator::Testing::MockDevice
    include ::RSpec::Matchers
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder

    def initialize(role, klass, settings, thread)
        @role = role
        @manager = Orchestrator::Testing::DeviceManager.new(thread, klass, settings)
        @manager.logger.level = :debug
        @manager.logger.use_blocking_writes = true
        @thread = thread
        @manager.start_local
    end

    attr_reader :thread, :manager, :role

    # Sends data to the module - emulating the remote device
    def transmit(raw, hex_string: false)
        STDOUT.puts "RX: #{raw.inspect}"

        data = if raw.is_a?(Array)
            array_to_str(raw)
        elsif hex_string
            hex_to_byte(raw)
        else
            raw
        end

        @manager.connection.receive(data)

        # Allow the data to be processed
        wait_tick

        self
    end

    alias responds transmit

    # Executes a function in the module
    def exec(function, *args)
        puts "INFO: executing #{function}( #{args.inspect[1..-2]} )"

        inst = @manager.instance
        raise 'module instance unavailable... Terminated?' unless inst

        if !inst.respond_to?(function) && inst.respond_to?(function, true)
            puts 'WARN: you are calling a private method'
        end
        @last_executed = inst.__send__(function, *args)

        self
    end

    # Defines a value that you expext to be sent to the device
    def should_send(raw, hex_string: false)
        data = if raw.is_a?(Array)
            array_to_str(raw)
        elsif hex_string
            hex_to_byte(raw)
        else
            raw
        end

        # Ensure data is processed
        wait_tick


        unless @manager.connection.check_outgoing(data)
            msg = String.new "module did not send #{raw.inspect} as expected\n"
            msg << "sent items are #{@manager.connection.outgoing.inspect}\n"

            cmd_inspect = proc { |cmd|
                insp = String.new " * data: #{cmd[:data].inspect} priority: #{cmd[:priority]}"
                insp << " name: #{cmd[:name]}" if cmd[:name]
                insp
            }

            queued = []
            waiting = @manager.processor.queue.waiting
            queued << cmd_inspect.call(waiting) if waiting
            queued += @manager.processor.queue.to_a.collect(&cmd_inspect)

            msg << if queued.empty?
                'send queue is empty'
            else
                "send queue contains: \n#{queued.join("\n")}"
            end

            self.class.raise_error msg
        end
        puts "INFO: Found #{raw.inspect}"

        self
    end


    # Prints the current contents of the queues
    # NOTE:: This is currently destructive! Probably don't use unless debugging
    def print_queues
        msg = String.new "sent items are #{@manager.connection.outgoing.inspect}\n"
        
        waiting = @manager.processor.queue.waiting

        cmd_inspect = proc { |cmd|
            insp = String.new " * data: #{cmd[:data].inspect} priority: #{cmd[:priority]}"
            insp << " name: #{cmd[:name]}" if cmd[:name]
            insp << " (sent, waiting response)" if cmd == waiting
            insp
        }

        queued = []
        queued << cmd_inspect.call(waiting) if waiting
        queued += @manager.processor.queue.to_a.collect(&cmd_inspect)

        msg << if queued.empty?
            'send queue is empty'
        else
            "send queue contains: \n#{queued.join("\n")}"
        end

        puts msg
        self
    end


    # Returns the response value of the last executed function
    def result
        res = @last_executed
        @last_executed = nil
        actual = if res.respond_to? :then
            co(res)
        else
            res
        end

        puts "INFO: execute result was #{actual.inspect}"

        actual
    end

    def status
        @manager.status
    end


    # Waits one reactor cycle
    def wait_tick(count = 1, defer = thread.defer)
        thread.next_tick do
            count -= 1
            if count == 0
                defer.resolve(true)
            else
                wait_tick(count, defer)
            end
        end
        co defer.promise
    end

    # Waits a number of milliseconds
    def wait(ms)
        wait_tick(2)

        defer = thread.defer
        thread.scheduler.in(ms + 10) do
            defer.resolve(true)
        end
        co defer.promise
    end

    def temporary_disconnect
        @manager.connection.disconnect
    end

    def device_offline
        @manager.connection.force_offline
    end

    def device_online
        @manager.connection.force_online
    end

    def self.raise_error(message)
        backtrace = caller
        backtrace.shift(2)
        err = RuntimeError.new message
        err.set_backtrace backtrace
        raise err
    end
end
