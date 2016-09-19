# frozen_string_literal: true

require 'set'

module Orchestrator
    module Security
        module SecurityMethods
            DEFAULT_PROTECT_PROC = proc { |user| user.support || user.sys_admin }
            def protect_method(*args, &block)
                @will_protect ||= {}
                block = DEFAULT_PROTECT_PROC unless block_given?

                args.each do |method|
                    meth = method.to_sym
                    @will_protect[meth] = block
                end
            end

            def grant_access?(instance, user, method)
                return true unless @will_protect && user

                block = @will_protect[method]
                return true unless block

                instance.instance_exec(user, method, &block)
            end
        end

        def can_access?(method, user = current_user)
            self.class.grant_access?(self, user, method.to_sym)
        end

        def self.included(klass)
            klass.extend SecurityMethods
        end
    end
end
