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

        errors = []
        bad_ids.each do |sys_id, issues|
            begin
                sys = Orchestrator::ControlSystem.find(sys_id)
                begin
                    sys.modules = sys.modules - issues[:mods]
                    sys.zones = sys.zones - issues[:zones]
                    sys.save! with_cas: true
                rescue ::Libcouchbase::Error::KeyExists
                    sys.reload
                    retry
                end
            rescue => e
                errors << sys.id
            end
        end

        puts "#{bad_ids.length - errors.length} issues resolved"
        puts "The following systems failed to save:\n\t#{errors.join("\n\t")}" if errors.present?

        puts "resetting metrics indicators..."
        failed = []
        Orchestrator::Module.all.each do |mod|
            begin
                 begin
                    mod.connected = true
                    mod.save! with_cas: true
                rescue ::Libcouchbase::Error::KeyExists
                    mod.reload
                    retry
                end
            rescue => e
                failed << mod.id
            end
        end

        if failed.empty?
            puts "metrics reset"
        else
            puts "The following modules failed to save:\n\t#{failed.join("\n\t")}" if failed.present?
        end
    end

    # Usage: rake check:offline['email@addresses,seperated@by.commas']
    desc 'Checks for offline devices and notifies by email if issues are found'
    task(:offline, [:emails] => [:environment])  do |task, args|
        OfflineMailer.offline_report(args[:emails])
    end
end
