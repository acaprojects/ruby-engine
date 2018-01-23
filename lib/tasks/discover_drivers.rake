# encoding: ASCII-8BIT
# frozen_string_literal: true

namespace :discover do

    desc 'Searches through default driver load directories and creates a list of available drivers'
    task :drivers => :environment do
        ::Orchestrator::Discovery.scan_for_modules
    end

end
