# frozen_string_literal: true

Orchestrator::Engine.routes.draw do

    # Restful access to services
    namespace :api do
        # Allows multiple routes to resolve to the one controller
        concern :mods do
            resources :modules do # modules have settings
                post 'start',   on: :member
                post 'stop',    on: :member
                get  'state',   on: :member
                get  'internal_state', on: :member
            end
        end

        # Trusted Sessions - Create Trust (returns id), Update Session and Destroy Trust
        # This is located in coauth
        resources :trusts

        resources(:systems, {as: :control_system}) do       # systems have settings and define what zone they are in
            post 'remove',  on: :member
            post 'start',   on: :member
            post 'stop',    on: :member
            post 'exec',    on: :member
            get  'state',   on: :member
            get  'funcs',   on: :member
            get  'count',   on: :member
            get  'types',   on: :member

            concerns :mods
            resources(:triggers, {controller: :system_triggers})
        end
        resources :dependencies do  # dependencies have settings
            post 'reload',  on: :member
        end
        resources :applications
        resources :domains
        resources :nodes
        resources :triggers
        resources :groups           # users define the groups they are in
        resources :zones            # zones define what groups can access them
        resources :users do
            get 'current',  on: :collection
        end
        resources :logs do
            get 'missing_connections', on: :collection
            get 'system_logs',         on: :collection
        end
        resources :system_triggers

        concerns  :mods

        resources :stats do
            get  'connections', on: :collection
            get  'panels',      on: :collection
            get  'triggers',    on: :collection
            get  'offline',     on: :collection
            get  'ignore_list', on: :collection
            post 'ignore',      on: :collection
        end

        resources :discovery do
            post 'scan',   on: :collection
        end
        resources :webhooks do
            post 'notify', on: :member
        end
        get 'webhooks/:id/notify', to: 'webhooks#show'

        # Tests are enabled in development
        if not Rails.env.production?
            resources :tests do
                get 'websocket', via: :all
            end
        end
    end

    # These are non-restful endpoints
    # Websockets and Eventsources
    get 'websocket', to: 'persistence#websocket', via: :all
end
