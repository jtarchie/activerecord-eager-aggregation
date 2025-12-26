# frozen_string_literal: true

require 'activerecord/eager/aggregation'
require 'active_record'
require 'rspec-sqlimit'

# Database configuration based on DB environment variable
# Usage: DB=postgresql bundle exec rspec
#        DB=mysql bundle exec rspec
#        DB=sqlite bundle exec rspec (default)
db_adapter = ENV.fetch('DB', 'sqlite')

def create_database_if_needed(adapter, config)
  case adapter
  when 'postgresql'
    require 'pg'
    conn = PG.connect(
      host: config[:host],
      port: config[:port],
      user: config[:username],
      password: config[:password],
      dbname: 'postgres'
    )
    result = conn.exec("SELECT 1 FROM pg_database WHERE datname = '#{config[:database]}'")
    if result.ntuples.zero?
      conn.exec("CREATE DATABASE #{config[:database]}")
      puts "Created PostgreSQL database: #{config[:database]}"
    end
    conn.close
  when 'mysql2'
    require 'mysql2'
    client = Mysql2::Client.new(
      host: config[:host],
      port: config[:port],
      username: config[:username],
      password: config[:password]
    )
    client.query("CREATE DATABASE IF NOT EXISTS #{config[:database]}")
    puts "Ensured MySQL database exists: #{config[:database]}"
    client.close
  end
rescue StandardError => e
  puts "Note: Could not create database (may already exist): #{e.message}"
end

case db_adapter
when 'postgresql', 'postgres', 'pg'
  require 'pg'
  db_config = {
    adapter: 'postgresql',
    host: ENV.fetch('POSTGRES_HOST', 'localhost'),
    port: ENV.fetch('POSTGRES_PORT', 5432).to_i,
    username: ENV.fetch('POSTGRES_USER', 'postgres'),
    password: ENV.fetch('POSTGRES_PASSWORD', 'postgres'),
    database: ENV.fetch('POSTGRES_DB', 'eager_aggregation_test')
  }
  create_database_if_needed('postgresql', db_config)
  ActiveRecord::Base.establish_connection(db_config)
  puts 'Running tests with PostgreSQL'
when 'mysql', 'mysql2'
  require 'mysql2'
  # Use 127.0.0.1 instead of localhost to force TCP connection (avoids socket issues)
  db_config = {
    adapter: 'mysql2',
    host: ENV.fetch('MYSQL_HOST', '127.0.0.1'),
    port: ENV.fetch('MYSQL_PORT', 3306).to_i,
    username: ENV.fetch('MYSQL_USER', 'root'),
    password: ENV.fetch('MYSQL_PASSWORD', 'mysql'),
    database: ENV.fetch('MYSQL_DB', 'eager_aggregation_test')
  }
  create_database_if_needed('mysql2', db_config)
  ActiveRecord::Base.establish_connection(db_config)
  puts 'Running tests with MySQL'
else
  require 'sqlite3'
  ActiveRecord::Base.establish_connection(
    adapter: 'sqlite3',
    database: ':memory:'
  )
  puts 'Running tests with SQLite (in-memory)'
end

# Define schema
ActiveRecord::Schema.define do
  create_table :users, force: true do |t|
    t.string :name
    t.boolean :active, default: true
    t.timestamps
  end

  create_table :posts, force: true do |t|
    t.integer :user_id
    t.string :title
    t.integer :score, default: 0
    t.boolean :published, default: false
    t.timestamps
  end

  create_table :categories, force: true do |t|
    t.string :name
    t.boolean :active, default: true
    t.timestamps
  end

  create_table :categorizations, force: true do |t|
    t.integer :post_id
    t.integer :category_id
    t.timestamps
  end
end

# Define models
class User < ActiveRecord::Base
  has_many :posts
  has_many :categorizations, through: :posts
  has_many :categories, through: :posts
  has_many :recent_posts, -> { order(created_at: :desc) }, class_name: 'Post'

  scope :active_authors, -> { where(active: true) }
  scope :by_name, -> { order(:name) }
  scope :by_name_desc, -> { order(name: :desc) }
end

class Post < ActiveRecord::Base
  belongs_to :user
  has_many :categorizations
  has_many :categories, through: :categorizations

  scope :published, -> { where(published: true) }
  scope :high_score, -> { where('score > 50') }
  scope :by_score, -> { order(:score) }
  scope :by_score_desc, -> { order(score: :desc) }
  scope :recent, -> { order(created_at: :desc) }
end

class Category < ActiveRecord::Base
  has_many :categorizations
  has_many :posts, through: :categorizations

  scope :active, -> { where(active: true) }
end

class Categorization < ActiveRecord::Base
  belongs_to :post
  belongs_to :category
end

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = '.rspec_status'

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  # Clean database before each test
  config.before(:each) do
    User.delete_all
    Post.delete_all
    Category.delete_all
    Categorization.delete_all
  end
end
