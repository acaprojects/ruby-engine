# frozen_string_literal: true

module Orchestrator
    module Api
        class StatsController < ApiController
            before_action :check_support
            before_action :set_period


            before_action :doorkeeper_authorize!, only: [:ignore_list, :ignore]


            # Number of websocket connections (UI's / Users)
            def connections
                render json: {
                    period_name: @pname,
                    period_start: @period_start,
                    interval: @period[0],
                    histogram: build_query('doc.connections_active')
                }
            end

            # Number of interface panels are connected
            def panels
                render json: {
                    period_name: @pname,
                    period_start: @period_start,
                    interval: @period[0],
                    histogram: build_query('doc.fixed_connections')
                }
            end

            # Number of active important triggers
            def triggers
                render json: {
                    period_name: @pname,
                    period_start: @period_start,
                    interval: @period[0],
                    histogram: build_query('doc.triggers_active')
                }
            end

            # Number of devices that were offline
            def offline
                render json: {
                    period_name: @pname,
                    period_start: @period_start,
                    interval: @period[0],
                    histogram: build_query('doc.modules_disconnected')
                }
            end

            # Used on the metrics page for ignoring issues
            # By storing this list in the database we ensure the view is consitent for all users
            def ignore_list
                render json: (Stats.bucket.get(:metrics_ignore_list, quiet: true) || {})
            end

            IGNORE_PARAMS = [:id, :sys_id, :klass, :timeout, :remove, :title, :reason]
            def ignore
                args = params.permit(IGNORE_PARAMS)
                user = current_user

                list = Stats.bucket.get(:metrics_ignore_list, quiet: true) || {}
                list.deep_symbolize_keys!
                time = Time.now.to_i

                # Perform list maintenance
                list.delete_if {|key, value| value[:timeout] < time }

                if args.has_key? :remove
                    list.delete args[:id].to_sym
                else
                    list[args[:id]] = {
                        id: args[:id],
                        sys_id: args[:sys_id],
                        user_id: user.id,
                        email_digest: user.email_digest,
                        name: user.name,
                        klass: args[:klass],
                        timeout: args[:timeout].to_i,
                        title: args[:title],
                        reason: args[:reason] || '',
                    }
                end

                Stats.bucket.set(:metrics_ignore_list, list)
                head :ok
            end


            protected


            # Month
            #  Interval: 86400 (point for each day ~29 points)
            # Week
            #  Interval: 21600 (point for each quarter day ~28 points)
            # Day
            #  Interval: 1800 (30min intervals ~48 points)
            # Hour
            #  Interval: 300 (5min ~12 points)
            PERIODS = {
                month: [1.day.to_i,      proc { Time.now.to_i - 29.days.to_i }],
                week:  [6.hours.to_i,    proc { Time.now.to_i - 7.days.to_i  }],
                day:   [30.minutes.to_i, proc { Time.now.to_i - 1.day.to_i   }],
                hour:  [5.minutes.to_i,  proc { Time.now.to_i - 1.hour.to_i  }]
            }.freeze

            SAFE_PARAMS = [
                :period
            ].freeze

            def set_period
                args = params.permit(SAFE_PARAMS)
                @pname = (args[:period] || :day).to_sym
                @period = PERIODS[@pname]
                @period_start = @period[1].call
            end


            def query
                {
                    bool: {
                        must: {
                            range: {
                                'doc.stat_snapshot_at' => {
                                    gte: @period_start
                                }
                            }
                        },
                        filter: {
                            bool: {
                                must: [{
                                    type: {
                                        value: :stats
                                    }
                                }]
                            }
                        }
                    }
                }
            end

            def aggregation(field)
                {
                    field => {
                        histogram: {
                            min_doc_count: 0,
                            field: 'doc.stat_snapshot_at',
                            interval: @period[0]
                        },
                        aggregations: {
                            bucket_stats: {
                                stats: {
                                    field: field
                                }
                            }
                        }
                    }
                }
            end

            AGGS = 'aggregations'
            BUCKETS = 'buckets'
            BSTATS = 'bucket_stats'

            def build_query(field)
                ::Elastic.client.search({
                    index: ::Elastic::INDEX,
                    body: {
                        query: query,
                        size: 0,
                        aggregations: aggregation(field)
                    }
                })[AGGS][field.to_s][BUCKETS].collect { |b| b[BSTATS] }
            end
        end
    end
end
