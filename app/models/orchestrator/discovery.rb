# frozen_string_literal: true

require 'set'

module Orchestrator
    class Discovery < Couchbase::Model
        design_document :disc


        attribute :name
        attribute :role
        attribute :description
        attribute :default
        attribute :class_name
        attribute :module_name
        attribute :makebreak
        attribute :settings,    default: lambda { {} }

        attribute :created_at,  default: lambda { Time.now.to_i }
        attribute :file_exists, default: true


        def self.scan_for_modules
            time = Time.now.to_i
            count = 0

            # TODO:: Load all existing modules
            # Check if they still exist

            Rails.application.config.orchestrator.module_paths.each do |path|
                Dir.glob("#{path}/**/*.rb") do |file|
                    begin
                        load file

                        klass_name = file[path.length..-4].camelize
                        klass = klass_name.constantize

                        # Check for existing entry
                        disc = Discovery.find_by_id "disc-#{klass_name}"

                        if klass.respond_to? :__discovery_details
                            if disc.nil?
                                disc = Discovery.new(klass.__discovery_details)
                                disc.class_name = klass_name
                            else
                                disc.update_attributes(klass.__discovery_details)
                            end

                            count += 1
                            disc.save!
                        elsif disc
                            # File no longer implements discovery API
                            disc.file_exists = false

                            count += 1
                            disc.save!
                        end
                    rescue Exception => e
                        puts e.message
                        puts e.backtrace.join("\n") if e.backtrace
                    end
                end
            end

            puts "Discovered #{count} drivers"
        end


        protected


        validates :class_name,  presence: true


        # Expire both the zone cache and any systems that use the zone
        before_save :set_id
        def set_id
            self.id = "disc-#{self.class_name}"
        end
    end
end
