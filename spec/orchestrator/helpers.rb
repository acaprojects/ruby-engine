require 'rails'
require 'orchestrator'


# Require models
require File.expand_path('../../../app/models/orchestrator/discovery', __FILE__)
require File.expand_path('../../../app/models/orchestrator/dependency', __FILE__)
require File.expand_path('../../../app/models/orchestrator/module', __FILE__)
require File.expand_path('../../../app/models/orchestrator/trigger', __FILE__)
require File.expand_path('../../../app/models/orchestrator/trigger_instance', __FILE__)
require File.expand_path('../../../app/models/orchestrator/zone', __FILE__)
require File.expand_path('../../../app/models/orchestrator/control_system', __FILE__)
require File.expand_path('../../../app/models/orchestrator/access_log', __FILE__)
require File.expand_path('../../../app/models/orchestrator/stats', __FILE__)
require File.expand_path('../../../app/models/orchestrator/edge_control', __FILE__)

::CouchbaseOrm::Base.descendants.each do |model|
    model.ensure_design_document!
end


class MockController
    def initialize(log)
        @log = log
        @loaded = {}
        @threads = [reactor]
    end

    def loaded?(mod_id)
        @loaded[mod_id.to_sym]
    end

    def add(mod)
        @loaded[mod.settings.id.to_sym] = mod
    end

    def log_unhandled_exception(e)
        @log << e
    end

    attr_reader :log, :threads
    attr_accessor :loaded
end

class MockLogger
    def initialize
        @listeners = Set.new
    end

    attr_reader :listeners

    def register(listener)
        if listener.is_a? Enumerable
            @listeners.merge(listener)
        else
            @listeners << listener
        end
    end

    def remove(listener)
        if listener.is_a? Enumerable
            @listeners.subtract(listener)
        else
            @listeners.delete listener
        end
    end
end

class MockModule
    def initialize(status = {})
        @status = status
        @thread = reactor
        @settings = OpenStruct.new
        @settings.id = "mod_1-#{rand(10..9999)}"
        @logger = MockLogger.new
    end

    def update_status(track, status, value)
        @status[status.to_sym] = value
        track.update(settings.id, status, value)
    end

    attr_reader   :status, :logger
    attr_accessor :settings, :thread
end

class MockSysProxy
    def initialize
        @modules = {}
        @id = "sys_1-#{rand(10..9999)}"
    end

    attr_reader :id, :modules

    def get(mod_name, index)
        mods = @modules[mod_name.to_sym]
        index = index - 1
        raise "bad index #{index}" if index < 0
        return mods[index] if mods
        nil
    end

    def add_module(mock_module, mod_name)
        @modules[mod_name.to_sym] ||= []
        @modules[mod_name.to_sym] << mock_module
    end
end

