# frozen_string_literal: true

namespace :migrate do

    desc 'Upgrades models to support distributed control'
    task :nodes => :environment do
        # Ensure all the Couchbase Views are in place
        ::Orchestrator::AccessLog
        ::Orchestrator::ControlSystem
        ::Orchestrator::Dependency
        ::Orchestrator::Discovery
        ::Orchestrator::EdgeControl
        ::Orchestrator::Module
        ::Orchestrator::Stats
        ::Orchestrator::Trigger
        ::Orchestrator::TriggerInstance
        ::Orchestrator::Zone

        begin
            ::CouchbaseOrm::Base.descendants.each do |model|
                model.ensure_design_document!
            end
        rescue ::Libcouchbase::Error::Timedout, ::Libcouchbase::Error::ConnectError, ::Libcouchbase::Error::NetworkError
            puts "error ensuring couchbase views"
        end

        # This adds support for statistics collection via elasticsearch
        edges = ::Orchestrator::EdgeControl.all.to_a
        edge = if edges[0]
            puts "Edge node exists with id #{edges.map(&:id)}"
            edges[0]
        else
            tmp = ::Orchestrator::EdgeControl.new
            id = ENV['ENGINE_NODE_ID']
            tmp.id = id if id
            tmp.name ||= 'Master Node'
            tmp.host_origin ||= 'http://127.0.0.1'
            tmp.save!
            puts "Edge node created with id #{tmp.id}"
            tmp
        end

        puts "Migrating modules"
        ::Orchestrator::Module.all.stream do |mod|
            begin
                if mod.edge_id.nil?
                    mod.edge_id = edge.id
                    mod.save!
                end
            rescue => e
                puts "Error saving #{mod.id}"
                puts e.message
                puts mod.errors.messages if mod.errors
                puts e.backtrace.join("\n")
            end
        end

        puts "Migrating systems"
        ::Orchestrator::ControlSystem.all.stream do |sys|
            begin
                if sys.edge_id.nil?
                    sys.edge_id = edge.id
                    sys.save!
                end
            rescue => e
                puts "Error saving #{sys.id}"
                puts e.message
                puts sys.errors.messages if sys.errors
                puts e.backtrace.join("\n")
            end
        end

        puts "\nENGINE_NODE_ID=\n#{ENV['ENGINE_NODE_ID'] || edge.id}"
    end
end
