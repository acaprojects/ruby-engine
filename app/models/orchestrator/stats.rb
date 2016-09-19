# frozen_string_literal: true

module Orchestrator
    class Stats < Couchbase::Model

        # zzz so
        design_document :zzz
        include ::CouchbaseId::Generator

        # 29 days < couchbase basic TTL format limit
        TTL = Rails.env.production? ? 29.days.to_i : 1.day.to_i

        attribute :modules_disconnected, default: 0
        attribute :triggers_active,      default: 0
        attribute :connections_active,   default: 0
        attribute :fixed_connections,    default: 0

        # TODO::
        attribute :nodes_offline,        default: 0
        belongs_to :edge, class_name: 'Orchestrator::EdgeControl'

        # Unique field in the index
        attribute :stat_snapshot_at


        def initialize(*args)
            super(*args)

            query_for_stats
        end

        def save
            super(ttl: TTL)
        end


        protected


        @@accessing    ||= Elastic.new(::Orchestrator::AccessLog)        # Connections active
        @@triggers     ||= Elastic.new(::Orchestrator::TriggerInstance)  # Triggers active
        @@disconnected ||= Elastic.new(::Orchestrator::Module)           # Modules disconnected


        def query_for_stats
            self.stat_snapshot_at = Time.now.to_i
            self.id = "zzz_#{CLUSTER_ID}-#{self.stat_snapshot_at}"
            self.edge_id = Remote::NodeId  # Edge that recorded this statistic

            #----------------------
            # => Connections active
            #----------------------
            query = @@accessing.query
            query.missing('doc.ended_at')    # Still active
            query.raw_filter([{         # Model was updated in the last 2min
                range: {
                    'doc.last_checked_at' => {
                        gte: self.stat_snapshot_at - 120
                    }
                }
            }])
            self.connections_active = @@accessing.count(query).to_i

            #----------------------------
            # => Fixed connections active
            #----------------------------
            query = @@accessing.query
            query.missing('doc.ended_at')    # Still active
            query.filter({
                'doc.installed_device' => [true]
            })
            query.raw_filter([{         # Model was updated in the last 2min
                range: {
                    'doc.last_checked_at' => {
                        gte: self.stat_snapshot_at - 120
                    }
                }
            }])
            self.fixed_connections = @@accessing.count(query).to_i

            #-------------------
            # => Triggers active
            #-------------------
            query = @@triggers.query
            query.filter({
                'doc.triggered' => [true],
                #important: [true],
                'doc.enabled' => [true]
            })
            self.triggers_active = @@triggers.count(query).to_i

            #------------------------
            # => Modules disconnected
            #------------------------
            query = @@disconnected.query
            query.raw_filter({
                range: {
                    'doc.updated_at' => {
                        lte: Time.now.to_i - 30
                    }
                }
            })
            query.filter({
                'doc.ignore_connected' => [false],
                'doc.connected' => [false],
                'doc.running' => [true]
            })
            self.modules_disconnected = @@disconnected.count(query).to_i
        end
    end
end
