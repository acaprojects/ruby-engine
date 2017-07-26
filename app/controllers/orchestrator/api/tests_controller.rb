# frozen_string_literal: true

# This file is ingored in production.
# The filesystem aspects use blocking IO.

if not Rails.env.production?
    require 'orchestrator/testing/testsocket_manager'
    require 'spider-gazelle/upgrades/websocket'
    require 'rake/file_list'

    module Orchestrator
        module Api
            class TestsController < ApiController
                before_action :check_admin

                def index
                    files = []
                    ::Rails.application.config.orchestrator.module_paths.each do |path|
                        list = ::Rake::FileList["#{path}/**/*.rb"].select { |mod|
                            mod.end_with?('_spec.rb')
                        }.to_a.map { |mod| mod[0..-4] }
                        files.concat(list) unless list.empty?
                    end
                    render json: files
                end

                def show
                    spec_file = params.permit(:id)[:id]
                    mod_file  = "#{spec_file.split('_spec')[0]}.rb"

                    path = ::Rails.application.config.orchestrator.module_paths.select { |dir|
                        mod_file.start_with?(dir)
                    }[0]
                    klass_name = mod_file[path.length..-4].camelize

                    begin
                        load mod_file
                        klass = klass_name.constantize

                        if klass.respond_to? :__discovery_details
                            render json: {
                                klass: klass_name,
                                details: klass.__discovery_details
                            }
                        else
                            render json: {
                                klass: klass_name
                            }
                        end
                    rescue Exception => e
                        render json: {
                            klass: klass_name,
                            error: e.message,
                            backtrace: e.backtrace.join("\n")
                        }
                    end
                rescue Exception => e
                    render json: {
                        error: e.message,
                        backtrace: e.backtrace.join("\n")
                    }
                end

                def websocket
                    hijack = request.env['rack.hijack']
                    if hijack
                        socket = hijack.call
                        spec = params.permit(:test_id)[:test_id] + '.rb'

                        begin
                            ws = ::SpiderGazelle::Websocket.new(socket, request.env)
                            ::Orchestrator::Testing::TestsocketManager.new(ws, spec)
                            ws.start
                        rescue => e
                            msg = ::String.new
                            msg << "Error starting websocket"
                            msg << "\n#{e.message}\n"
                            msg << e.backtrace.join("\n") if e.respond_to?(:backtrace) && e.backtrace
                            logger.error msg
                            raise e
                        end

                        throw :async     # to prevent rails from complaining
                    else
                        head :method_not_allowed
                    end
                end
            end
        end
    end
end
