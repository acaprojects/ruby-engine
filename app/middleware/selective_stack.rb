
# Based of code from
# * http://stackoverflow.com/questions/26922343/omniauthnosessionerror-you-must-provide-a-session-to-use-omniauth-configur
# * https://blog.codeship.com/building-a-json-api-with-rails-5/

class SelectiveStack
    def initialize(app)
        @app = app
        @stack = middleware_stack.build(@app)
    end

    def call(env)
        if env["PATH_INFO"].include?("/api/")
            @app.call(env)
        else
            @stack.call(env)
        end
    end


    private


    def middleware_stack
        ::ActionDispatch::MiddlewareStack.new.tap do |middleware|
            # needed for OmniAuth
            middleware.use ::ActionDispatch::Cookies
            middleware.use ::Rails.application.config.session_store, ::Rails.application.config.session_options
            middleware.use ::OmniAuth::Builder, &OmniAuthConfig if defined?(::OmniAuth)
            # needed for Doorkeeper /oauth views
            middleware.use ::ActionDispatch::Flash
        end
    end
end
