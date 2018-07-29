# frozen_string_literal: true

module Orchestrator
    module Service
        module Mixin
            include ::Orchestrator::Device::Mixin

            undef send
            undef disconnect
            undef enable_multicast_loop

            def request(method, path, **options, &blk)
                defer = @__config__.thread.defer
                options[:method] = method
                options[:path] = path
                options[:defer] = defer
                options[:max_waits] = 0  # HTTP will only ever respond to a request
                options[:on_receive] = blk if blk     # on command success
                @__config__.thread.schedule do
                    @__config__.processor.queue_command(options)
                end
                defer.promise
            end

            def get(path, **options, &blk)
                request(:get, path, options, &blk)
            end

            def post(path, **options, &blk)
                request(:post, path, options, &blk)
            end

            def put(path, **options, &blk)
                request(:put, path, options, &blk)
            end

            def delete(path, **options, &blk)
                request(:delete, path, options, &blk)
            end

            def remote_address
                @__config__.settings.uri
            end

            def remote_port
                addr = ::Addressable::URI.parse(remote_address)
                addr.port || (addr.scheme == 'http' ? 80 : 443)
            end

            def clear_cookies
                begin
                    @__config__.connection.server.cookiejar.clear_cookies
                rescue
                end
            end

            def middleware
                begin
                    @__config__.connection.server.middleware
                rescue
                    []
                end
            end
        end
    end
end
