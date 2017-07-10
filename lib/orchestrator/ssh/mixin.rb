# frozen_string_literal: true

require 'shellwords'

module Orchestrator
    module Ssh
        module Mixin
            include ::Orchestrator::Device::Mixin

            undef send
            undef enable_multicast_loop

            def exec(*args, **options, &block)
                # Escape the arguments as required
                cmd = args.length > 1 ? Shellwords.join(args) : args[0]

                options[:data] = cmd
                options[:defer] = @__config__.thread.defer

                if options[:stream] || block_given?
                    options[:stream] ||= block
                    options[:wait] = false
                    options[:resp] = @__config__.thread.defer
                    options[:defer].resolve(options[:resp].promise)
                end

                @__config__.thread.schedule do
                    @__config__.processor.queue_command(options)
                end
                options[:defer].promise
            end
        end
    end
end
