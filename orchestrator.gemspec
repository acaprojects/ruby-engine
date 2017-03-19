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

    s.add_dependency 'rake',    '~> 12'
    s.add_dependency 'rails',   '~> 5.0'    # Web Framework
    s.add_dependency 'libuv',   '~> 3.1'    # High performance IO reactor for ruby
    s.add_dependency 'oauth',   '~> 0.5'    # OAuth protocol support
    s.add_dependency 'uv-rays', '~> 2.0'    # Evented networking library
    s.add_dependency 'addressable',  '~> 2.4'     # IP address utilities
    s.add_dependency 'algorithms',   '~> 0.6'     # Priority queue
    s.add_dependency 'couchbase-orm','~> 0'       # Database adaptor
    s.add_dependency 'doorkeeper-couchbase', '~> 1.0'
    s.add_dependency 'co-elastic-query', '~> 3.0' # Query builder
    s.add_dependency 'spider-gazelle',   '~> 3.0' # RACK Webserver

    s.add_development_dependency 'rspec','~> 3.5' # Testing framework
    s.add_development_dependency 'yard', '~> 0.9' # Comment based documentation generation


    s.files = Dir["{lib,app,config}/**/*"] + %w(Rakefile orchestrator.gemspec README.md LICENSE.md)
    s.test_files = Dir['spec/**/*']
    s.extra_rdoc_files = ['README.md']

    s.require_paths = ['lib']
end
