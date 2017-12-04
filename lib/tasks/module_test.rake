# frozen_string_literal: true
# encoding: ASCII-8BIT

require 'orchestrator/testing/mock_device'

namespace :module do

    # Usage: rake module:test['/Users/steve/Documents/projects/aca-device-modules/modules/extron/switcher/dxp_spec.rb']

    desc 'runs the test for a logic, device or service module'
    task :test, [:filename] => [:environment] do |task, args|
        puts "Running tests for #{args[:filename]}"
        load args[:filename]
    end
end
