# frozen_string_literal: true

namespace :migrate do

    desc 'Migrate modules so that statistics queries are accurate'

    task :stats => :environment do
        # This adds support for statistics collection via elasticsearch

        time = Time.now.to_i
        ::Orchestrator::Module.all.each do |mod|
            mod.ignore_connected = false
            mod.updated_at = time if mod.updated_at.nil?
            mod.save!
        end
    end

end
