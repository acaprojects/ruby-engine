# frozen_string_literal: true

require 'spider-gazelle/upgrades/websocket'

module Orchestrator
    class PersistenceController < ApiController
        CONTROL = Control.instance

        # Supply a bearer_token param for oauth
        HIJACK = 'rack.hijack'

        def websocket
            hijack = request.env[HIJACK]
            if hijack && CONTROL.ready
                socket = hijack.call

                # grab user for authorization checks in the web socket
                user = current_user
                begin
                    ip = request.env['HTTP_X_REAL_IP'] || request.remote_ip
                    ws = ::SpiderGazelle::Websocket.new(socket, request.env)
                    fixed_device = params.has_key?(:fixed_device)
                    WebsocketManager.new(ws, user, fixed_device, ip)
                    ws.start
                rescue => e
                    socket.close

                    msg = String.new
                    msg << "Error starting websocket"
                    msg << "\n#{e.message}\n"
                    msg << e.backtrace.join("\n") if e.respond_to?(:backtrace) && e.backtrace
                    logger.error msg
                end

                throw :async     # to prevent rails from complaining
            else
                head :method_not_allowed
            end
        end
    end
end
