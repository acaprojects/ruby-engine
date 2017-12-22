# frozen_string_literal: true

require 'set'

module Orchestrator
    class Discovery < CouchbaseOrm::Base
        design_document :disc


        attribute :name,        type: String
        attribute :role,        type: String
        attribute :description, type: String
        attribute :default      # This can be a string (URL) or an integer (Port Number)
        attribute :class_name,  type: String
        attribute :module_name, type: String
        attribute :makebreak,   type: Boolean
        attribute :settings,    type: Hash,    default: lambda { {} }

        attribute :created_at,  type: Integer, default: lambda { Time.now }
        attribute :file_exists, type: Boolean, default: true


        # NOTE:: Assumes it is run from a rake task (FileList defined by Rake GEM)
        def self.scan_for_modules
            time = Time.now.to_i
            count = 0

            # TODO:: Load all existing modules
            # Check if they still exist

            Rails.application.config.orchestrator.module_paths.each do |path|
                FileList["#{path}/**/*.rb"].reject {|mod| mod.end_with?('_spec.rb') }.each do |file|
                    begin
                        load file

                        file_name = file[path.length..-4] # minus the .rb
                        class_names = File.readlines(file).select { |line|
                            line.include?('class ')
                        }.collect { |line|
                            klass = line.split("<")[0].gsub(/class/, "").strip
                            klass.start_with?('::') ? klass : "::#{klass}"
                        }.select { |klass|
                            klass.underscore == file_name
                        }

                        if class_names.empty?
                            ::STDERR.puts "no class names matched in file #{file}"
                            next
                        end

                        klass_name = class_names[0]
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
                        ::STDERR.puts "#{file} error #{e.message}"
                        ::STDERR.puts e.backtrace.select { |line| line.include?(path) }.join("\n") if e.backtrace
                    end
                end
            end

            ::STDERR.puts "Discovered #{count} drivers"
        end


        protected


        validates :class_name,  presence: true


        # Expire both the zone cache and any systems that use the zone
        before_create :set_id
        def set_id
            ::STDERR.puts "* Discovered #{self.class_name} #{self.name}"
            self.id = "disc-#{self.class_name}"
        end
    end
end
