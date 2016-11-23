# frozen_string_literal: true

namespace :migrate do

    desc 'Upgrades models to support distributed control'
    task :nodes => :environment do
        # This adds support for statistics collection via elasticsearch
        edges = ::Orchestrator::EdgeControl.all.to_a
        edge = if edges[0]
            edges[0]
        else
            tmp = ::Orchestrator::EdgeControl.new
            tmp.name ||= 'Master Node'
            tmp.host_origin ||= 'http://127.0.0.1'
            tmp.save!
            puts "Edge node created with id #{tmp.id}"
            tmp
        end

        puts "Migrating modules"
        ::Orchestrator::Module.all.stream do |mod|
            if mod.edge_id.nil?
                mod.edge_id = edge.id
                mod.save!
            end
        end

        puts "Migrating systems"
        ::Orchestrator::ControlSystem.all.stream do |sys|
            if sys.edge_id.nil?
                sys.edge_id = edge.id
                sys.save!
            end
        end
    end

end
