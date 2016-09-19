# encoding: ASCII-8BIT
# frozen_string_literal: true

require 'rails'
require 'protocols/oauth'


describe "oauth protocol helper" do
    before :each do
        site = 'https://photos.example.net'
        @oauth = Protocols::OAuth.new key: 'dpf43f3p2l4k3l03', secret: 'kd94hf93k423kf44', site: site
        @http = UV::HttpEndpoint.new site
    end

    it "should sign a oauth header" do
        req = @http.post({
            path: '/initialize'
        })
        @oauth.options.merge!({
            oauth_timestamp: '137131200',
            oauth_nonce: 'wIjqoS',
            oauth_callback: 'http://printer.example.com/ready'
        })

        head = {}
        @oauth.request(req, head, nil)

        expect(head['Authorization'].class).to be(String)
    end

    it "should include params" do
        req = @http.post({
            path: '/initialize',
            query: {
                bob: 'is cool'
            }
        })
        @oauth.options.merge!({
            oauth_timestamp: '137131200',
            oauth_nonce: 'wIjqoS',
            oauth_callback: 'http://printer.example.com/ready'
        })

        head = {}
        req = @oauth.request(req, head, nil)

        expect(head['Authorization'].class).to be(String)
    end
end
