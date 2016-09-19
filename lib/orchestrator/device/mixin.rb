# frozen_string_literal: true

module Orchestrator
    module Device
        module Mixin
            include ::Orchestrator::Core::Mixin

            def send(data, options = {}, &blk)
                options[:data] = data
                options[:defer] = @__config__.thread.defer
                options[:on_receive] = blk if blk     # on command success
                @__config__.thread.schedule do
                    @__config__.processor.queue_command(options)
                end
                options[:defer].promise
            end

            def disconnect
                @__config__.thread.schedule do
                    @__config__.connection.disconnect
                end
            end

            def config(options)
                @__config__.thread.schedule do
                    @__config__.processor.config = options
                end
            end

            def defaults(options)
                @__config__.thread.schedule do
                    @__config__.processor.send_options(options)
                end
            end

            def remote_address
                @__config__.settings.ip
            end

            def remote_port
                @__config__.settings.port
            end

            def enable_multicast_loop(state = true)
                transport = @__config__.connection
                if transport.respond_to? :enable_multicast_loop
                    if state
                        transport.enable_multicast_loop
                    else
                        transport.disable_multicast_loop
                    end
                end
            end
        end
    end
end
