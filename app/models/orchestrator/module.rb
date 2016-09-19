# frozen_string_literal: true

require 'addressable/uri'

module Orchestrator
    class Module < Couchbase::Model
        design_document :mod
        include ::CouchbaseId::Generator


        # The classes / files that this module requires to execute
        # Defines module type
        # Requires dependency_id to be set
        belongs_to :dependency,     class_name: 'Orchestrator::Dependency'
        belongs_to :control_system, class_name: 'Orchestrator::ControlSystem'
        belongs_to :edge,           class_name: 'Orchestrator::EdgeControl'


        # Device module
        def hostname; ip; end
        def hostname=(host); ip = host; end
        attribute :ip
        attribute :tls
        attribute :udp
        attribute :port
        attribute :makebreak,   default: false

        # HTTP Service module
        attribute :uri

        # Custom module names (in addition to what is defined in the dependency)
        attribute :custom_name
        attribute :settings,    default: lambda { {} }

        attribute :updated_at,  default: lambda { Time.now.to_i }
        attribute :created_at,  default: lambda { Time.now.to_i }
        attribute :role         # cache the dependency role locally for load order

        # Connected state in model so we can filter and search on it
        attribute :connected,   default: true
        attribute :running,     default: false
        attribute :notes

        # Don't include this module in statistics or disconnected searches
        # Might be a device that commonly goes offline (like a PC or Display that only supports Wake on Lan)
        attribute :ignore_connected,   default: false


        # helper method for looking up the manager
        def manager
            ::Orchestrator::Control.instance.loaded? self.id
        end


        # Returns the node currently running this module
        def node
            return @node_cache if @node_cache
            # NOTE:: Same function in control_system.rb
            @nodes ||= Control.instance.nodes
            @node_id ||= self.edge_id.to_sym
            @node_cache = @nodes[@node_id]
        end


        # Loads all the modules for this node
        def self.all
            # ascending order by default (device, service then logic)
            by_module_type(stale: false)
        end
        view :by_module_type

        # Finds all the modules belonging to a particular dependency
        def self.dependent_on(dep_id)
            by_dependency({key: dep_id, stale: false})
        end
        view :by_dependency

        def self.on_node(edge_id)
            by_node({key: edge_id, stale: false})
        end
        view :by_node


        protected


        validates :dependency, presence: true
        validates :edge_id,    presence: true
        validate  :configuration

        def configuration
            return unless dependency
            case dependency.role
            when :device
                self.role = 1
                self.port = (self.port || dependency.default).to_i

                errors.add(:ip, 'cannot be blank') if self.ip.blank?
                errors.add(:port, 'is invalid') unless self.port.between?(1, 65535)

                # Ensure tls and upd values are correct
                # can't have udp + tls
                self.udp = !!self.udp
                if self.udp
                    self.tls = false
                else
                    self.tls = !!self.tls
                end

                begin
                    url = Addressable::URI.parse("http://#{self.ip}:#{self.port}/")
                    url.scheme && url.host && url
                rescue
                    errors.add(:ip, 'address / hostname or port are not valid')
                end
            when :service
                self.role = 2

                self.tls = nil
                self.udp = nil

                begin
                    self.uri ||= dependency.default
                    url = Addressable::URI.parse(self.uri)
                    url.scheme && url.host && url
                rescue
                    errors.add(:uri, 'is an invalid URI')
                end
            else # logic
                self.connected = true  # it is connectionless
                self.tls = nil
                self.udp = nil
                self.role = 3
                if control_system.nil?
                    errors.add(:control_system, 'must be associated')
                end
            end
        end

        before_delete :unload_module
        def unload_module
            ::Orchestrator::Control.instance.unload(self.id)
            # Find all the systems with this module ID and remove it
            ControlSystem.using_module(self.id).each do |cs|
                cs.modules.delete(self.id)
                cs.save
            end
        end
    end
end
