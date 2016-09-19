source 'https://rubygems.org'
gemspec


# Database requirements
if RUBY_PLATFORM == 'java'
    gem 'couchbase-jruby-model', git: 'https://github.com/stakach/couchbase-jruby-model.git'
    gem 'jruby-pageant' # (required by puma?)
else
    gem 'couchbase'
    gem 'couchbase-model', git: 'https://github.com/stakach/couchbase-ruby-model'
end
