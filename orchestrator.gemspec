# encoding: utf-8
# frozen_string_literal: true

$:.push File.expand_path('../lib', __FILE__)
require 'orchestrator/version'

Gem::Specification.new do |s|
    s.name        = 'orchestrator'
    s.version     = Orchestrator::VERSION
    s.authors     = ['Stephen von Takach']
    s.email       = ['steve@advancedcontrol.com.au']
    s.license     = 'CC BY-NC-SA'
    s.homepage    = 'https://github.com/acaprojects/ruby-engine'
    s.summary     = 'A distributed system for building automation'
    s.description = 'A building and Internet of Things automation system'

    s.add_dependency 'rake',    '~> 12.2'     # Task running framework
    s.add_dependency 'rspec',   '~> 3.5'    # Testing framework
    s.add_dependency 'rails',   '~> 6.0'    # Web framework
    s.add_dependency 'libuv',   '4.0.9'    # High performance IO reactor for ruby
    s.add_dependency 'oauth',   '~> 0.5'    # OAuth protocol support
    s.add_dependency 'rbtrace', '~> 0.4'    # OAuth protocol support
    s.add_dependency 'xorcist', '~> 1.0'    # Inproves string XOR speed for netsnmp
    s.add_dependency 'netsnmp', '~> 0.1'    # SNMP protocol support
    s.add_dependency 'uv-rays', '~> 2.0'    # Evented networking library
    s.add_dependency 'ruby-ntlm',    '0.0.4'      # Ruby NTLM parsing
    s.add_dependency 'yajl-ruby',    '~> 1.4'     # Improved JSON processing
    s.add_dependency 'addressable',  '~> 2.4'     # IP address utilities
    s.add_dependency 'algorithms',   '~> 0.6'     # Priority queue
    s.add_dependency 'lograge',      '~> 0.10'    # single line logs for API requests
    s.add_dependency 'mono_logger',  '~> 1.1'     # Lock free logging
    s.add_dependency 'evented-ssh',  '~> 0'       # SSH protocol support
    s.add_dependency 'couchbase-orm','~> 1'       # Database adaptor
    s.add_dependency 'doorkeeper-couchbase', '~> 1.0'
    s.add_dependency 'co-elastic-query', '~> 3.0' # Query builder
    s.add_dependency 'spider-gazelle',   '~> 3.2' # RACK Webserver

    s.add_development_dependency 'yard',   '~> 0.9' # Comment based documentation generation
    s.add_development_dependency 'byebug', '~> 9.0' # Debugging console


    s.files = Dir["{lib,app,config}/**/*"] + %w(Rakefile orchestrator.gemspec README.md LICENSE.md)
    s.test_files = Dir['spec/**/*']
    s.extra_rdoc_files = ['README.md']

    s.require_paths = ['lib']
end
