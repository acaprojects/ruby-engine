require 'rails'
require 'orchestrator'
require File.expand_path("../helpers", __FILE__)


class MockCtrl
    def start

    end

    def stop

    end

    def unload

    end

    def loaded?

    end

    def update
        
    end

    # This is technically the dependency manager
    def load(dep, force)
        # returns a promise
    end

    # this is technically the TCP object
    def write(data)
        # returns a promise
    end
end


describe Orchestrator::Remote::Proxy do
    
end
