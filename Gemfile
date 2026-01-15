# frozen_string_literal: true

source 'https://rubygems.org'

# Specify your gem's dependencies in activerecord-eager-aggregation.gemspec
gemspec

gem 'irb'
gem 'rake', '~> 13.0'

gem 'rspec', '~> 3.0'
gem 'rspec-sqlimit'
gem 'rubocop'

# Database adapters - use DB env var to select which to load
gem 'sqlite3', '~> 2.1'

group :mysql do
  gem 'mysql2', '~> 0.5'
end

group :postgresql do
  gem 'pg', '~> 1.5'
end
