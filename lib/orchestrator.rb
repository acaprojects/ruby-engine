# frozen_string_literal: true

# Gems
require 'uv-rays'
require 'co-elastic-query'
require 'couchbase-orm'
require 'orchestrator/engine'
require 'coauth'

# Optional utility modules
require 'orchestrator/utilities/transcoder' # functions for data manipulation
require 'orchestrator/utilities/constants'  # constants for readable code
require 'orchestrator/utilities/security'   # helper methods for protecting code access

# System Main
require 'orchestrator/dependency_manager'   # Manages code loading
require 'orchestrator/websocket_manager'    # Websocket interface
require 'orchestrator/datagram_server'      # UDP abstraction management
require 'orchestrator/encryption'           # For storing sensitive information in the database
require 'orchestrator/control'              # Module control and system loader
require 'orchestrator/version'              # orchestrator version
require 'orchestrator/system'               # This is the source of truth for all system information
require 'orchestrator/status'               # Manages status subscriptions across threads
require 'orchestrator/logger'               # Logs events of interest as well as coordinating live log feedback
require 'orchestrator/errors'               # A list of errors that can occur within the system

# Core Abstractions
require 'orchestrator/core/module_manager'  # Base class of logic, device and service managers
require 'orchestrator/core/schedule_proxy'  # Common proxy for all module schedules
require 'orchestrator/core/requests_proxy'  # Sends a command to all modules of that type
require 'orchestrator/core/request_proxy'   # Sends a command to a single module
require 'orchestrator/core/system_proxy'    # prevents stale system objects (maintains loose coupling)
require 'orchestrator/core/mixin'           # Common mixin functions for modules classes

# Logic abstractions
require 'orchestrator/logic/manager'        # control system manager for logic modules
require 'orchestrator/logic/mixin'          # helper functions for logic module classes

# Device abstractions
require 'orchestrator/device/transport_makebreak'
require 'orchestrator/device/transport_multicast'
require 'orchestrator/device/command_queue'
require 'orchestrator/device/transport_tcp'
require 'orchestrator/device/transport_udp'
require 'orchestrator/device/processor'
require 'orchestrator/device/manager'
require 'orchestrator/device/mixin'

# SSH abstractions
require 'orchestrator/ssh/transport_ssh'
require 'orchestrator/ssh/manager'
require 'orchestrator/ssh/mixin'

# Service abstractions
require 'orchestrator/service/transport_http'
require 'orchestrator/service/manager'
require 'orchestrator/service/mixin'

# Trigger logic
require 'orchestrator/triggers/state'
require 'orchestrator/triggers/manager'
require 'orchestrator/triggers/module'

# Remote system logic
require 'orchestrator/remote/proxy'
require 'orchestrator/remote/edge'
require 'orchestrator/remote/master'
require 'orchestrator/remote/manager'


module Orchestrator
end
