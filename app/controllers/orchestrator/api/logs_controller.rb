# frozen_string_literal: true

module Orchestrator
    module Api
        class LogsController < ApiController
            before_action :doorkeeper_authorize!
            
            before_action :check_admin, except: :missing_connections
            before_action :check_support, only: :missing_connections


            # deal with live reload   filter
            @@elastic ||= Elastic.new(AccessLog)


            UserId = 'doc.user_id'.freeze
            def index
                query = @@elastic.query(params)

                # Filter systems via user_id
                if params.has_key? :user_id
                    user_id = params.permit(:user_id)[:user_id]
                    query.filter({
                        UserId => [user_id]
                    })
                end

                results = @@elastic.search(query) do |entry|
                    entry.as_json.tap do |json|
                        json[:systems] = Array(ControlSystem.find_by_id(json[:systems]).as_json(only: [:id, :name]))
                    end
                end
                render json: results
            end


            # Who accessed a particular system and when
            Systems = 'doc.systems'.freeze
            LOG_PARAMS = [:sys_id, :starting, :ending, :installed, :suspected, :user]
            def system_logs
                params.require(:sys_id)
                args = params.permit(LOG_PARAMS)

                query = @@elastic.query(params)

                # Filter systems via sys_id
                custom = [{
                    term: {
                        Systems => args[:sys_id]
                    }
                }]

                # All connections who end after this
                if args.has_key? :starting
                    custom << {
                        or: [
                            # Never ending
                            {
                                missing: { field: 'doc.ended_at' }
                            },

                            # Or ends after the start time we requested
                            {
                                range: {
                                    'doc.ending' => {
                                        gt: args[:starting].to_i
                                    }
                                }
                            }
                        ]
                    }
                end

                # All connections who started before this
                if args.has_key? :ending
                    custom << {
                        range: {
                            'doc.created_at' => {
                                lt: args[:ending].to_i
                            }
                        }
                    }
                end

                # Remove or include installation hardware
                if args.has_key? :installed
                    installed = args[:installed] == 'true'
                    custom << {
                        term: {
                            'doc.installed_device' => installed
                        }
                    }
                end

                if args.has_key? :suspected
                    suspected = args[:suspected] == 'true'
                    custom << {
                        term: {
                            'doc.suspected' => suspected
                        }
                    }
                end

                if args.has_key? :user
                    custom << {
                        term: {
                            'doc.user_id' => args[:user]
                        }
                    }
                end

                query.raw_filter({
                    and: custom
                })

                results = @@elastic.search(query)
                render json: results.as_json({
                    include: {user: User::PUBLIC_DATA}
                })
            end


            @@cs ||= Elastic.new(ControlSystem)
            SYS_JSON = {only: [:id, :name, :installed_ui_devices]}

            # 1. Grab the system ids that we are interested in
            # 2. Perform an aggregation query to get connection counts
            # 3. Return the systems that are missing or whose count is not high enough
            def missing_connections
                # System IDs Query
                query = @@cs.query
                query.range({
                    'doc.installed_ui_devices' => {
                        gt: 0
                    }
                })
                search_json = @@cs.generate_body(query)
                body = search_json[:body]
                body[:from] = 0
                body[:size] = 10_000  # Elastic search max
                result = ::Elastic.search(search_json)

                system_ids = result[::Elastic::HITS][::Elastic::HITS].map {|entry| entry[::Elastic::ID]}
                missing = {}

                if not system_ids.empty?
                    # Aggregation Query
                    now = Time.now.to_i
                    two_min_ago = now - 2.minutes.to_i
                    one_min_ago = now - 1.minutes.to_i
                    search_json = {
                        index: search_json[:index],
                        body: {
                            query: {
                                filtered: {
                                    filter: {
                                        and: [
                                            {
                                                type: {
                                                    value: :alog
                                                }
                                            },
                                            {
                                                term: {
                                                    'doc.installed_device' => true
                                                }
                                            },
                                            {
                                                terms: {
                                                    'doc.system_id' => system_ids
                                                }
                                            },

                                            # last seen within the last 2min
                                            {
                                                range: {
                                                    'doc.last_checked_at' => {
                                                        gt: two_min_ago
                                                    }
                                                }
                                            },
                                            {
                                                # ES is eventually consistent so we need to give it a chance
                                                or: [
                                                    {
                                                        missing: { 
                                                            field: 'doc.ended_at'
                                                        }
                                                    },
                                                    {
                                                        range: {
                                                            'doc.ended_at' => {
                                                                gt: one_min_ago
                                                            }
                                                        }
                                                    }
                                                ]
                                            }
                                        ]
                                    }
                                }
                            },
                            aggs: {
                                system_count: {
                                    terms: {
                                        field: :system_id,
                                        size: 0
                                    }
                                }
                            },
                            from: 0,
                            size: 0
                        }
                    }

                    # Join the results
                    result = Elastic.search(search_json)
                    buckets = result['aggregations'.freeze]['system_count'.freeze]['buckets'.freeze]
                    
                    connections = {}
                    buckets.each do |sys|
                        connections[sys['key'.freeze]] = sys['doc_count'.freeze].to_i
                    end

                    systems = ControlSystem.find_by_id system_ids
                    systems.each do |sys|
                        connection = connections[sys.id]

                        if connection.nil? 
                            missing[sys.id] = {
                                system: sys.as_json(SYS_JSON),
                                connections: 0
                            }

                        elsif sys.installed_ui_devices > connection
                            missing[sys.id] = {
                                system: sys.as_json(SYS_JSON),
                                connections: connection
                            }
                        end
                    end
                end

                render json: { missing: missing }
            end
        end
    end
end
