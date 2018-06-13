# encoding: ASCII-8BIT
# frozen_string_literal: true

namespace :check do
    desc 'Checks all systems to ensure they have valid data'
    task :integrity => :environment do
        puts "Checking all systems for inconsistencies"

        # Collect the issues
        bad_ids = {}
        Orchestrator::ControlSystem.all.stream do |sys|
            sys.modules.each do |mod_id|
                mod = Orchestrator::Module.find_by_id(mod_id)
                if mod.nil?
                    bad_ids[sys.id] ||= {mods:[], zones:[]}
                    bad_ids[sys.id][:mods] << mod_id
                end
            end

            sys.zones.each do |zone_id|
                zone = Orchestrator::Zone.find_by_id(zone_id)
                if zone.nil?
                    bad_ids[sys.id] ||= {mods:[], zones:[]}
                    bad_ids[sys.id][:zones] << zone_id
                end
            end
        end

        # resolve the issues
        puts "Found issues with #{bad_ids.length} systems"

        exit 0 if bad_ids.length == 0

        bad_ids.each do |sys_id, issues|
            sys = Orchestrator::ControlSystem.find(sys_id)
            sys.modules = sys.modules - issues[:mods]
            sys.zones = sys.zones - issues[:zones]
            sys.save!
        end

        puts "#{bad_ids.length} issues resolved"
    end
end
