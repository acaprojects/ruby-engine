# frozen_string_literal: true

require 'set'

module Orchestrator
    # Provide the ability to hide public module methods from being exposed
    # via the API. This may be used to keep methods accessible for cross-module
    # comms or internal use, without publishing to external users.
    #
    # Methods hidden here may still be executed via the API. To restrict access
    # in addition to obfuscating use ::Orchestrator::Security.
    module Clandestine
        module ClandestineMethods
            # Hide a method, or set of methods from the API.
            #
            # May be used inline with the definition:
            #
            #     hidden def foo
            #         ...
            #     end
            #
            # Or as a declarative syntax for internalising multiple driver
            # methods:
            #
            #     hide :foo, :bar, :baz
            #
            def hidden(*methods)
                methods = methods.map(&:to_sym)

                const_set :HIDDEN_METHODS, Set.new \
                    unless const_defined? :HIDDEN_METHODS

                if methods.count == 1
                    method = methods.first
                    HIDDEN_METHODS << method
                    method
                else
                    HIDDEN_METHODS.merge methods
                    methods
                end
            end

            alias hide hidden
        end

        module_function

        def included(base)
            base.prepend ClandestineMethods
        end
    end
end
