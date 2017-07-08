# frozen_string_literal: true

require 'shellwords'

module Orchestrator
    module Ssh
        module Mixin
            include ::Orchestrator::Device::Mixin

            undef send
            undef enable_multicast_loop

            def exec(*args, **options, &block)
                # Escape the arguments
                cmd = Shellwords.join(args)
                options[:data] = cmd
                if options[:stream] || block_given?
                    options[:stream] ||= block
                    options[:wait] = false
                end
                options[:defer] = @__config__.thread.defer
                @__config__.thread.schedule do
                    @__config__.processor.queue_command(options)
                end
                options[:defer].promise
            end
        end
    end
end
