# frozen_string_literal: true

require 'oauth'

module Protocols; end
class Protocols::OAuth
    def initialize(key:, secret:, site:, token: nil, options: {})
        @consumer = OAuth::Consumer.new key, secret, site: site
        @token = token
        @options = options
    end


    attr_accessor :token
    attr_reader   :options, :consumer


    def request(request, head, body)
        opts = @options.merge request.options

        args = [head]
        args.unshift body if [:post, :put, :patch].include?(request.method)

        path = request.path.dup
        if opts[:query]
            path = request.encode_query(path, opts[:query])
        end

        req = @consumer.create_signed_request(request.method, path, @token, opts, *args)
        head['Authorization'] = req['Authorization']

        [head, body]
    end

    def site=(site)
        @consumer.site = site
    end
end
