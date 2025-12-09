# frozen_string_literal: true

require "activerecord/eager/aggregation"
require "active_record"
require "rspec-sqlimit"

# Setup in-memory SQLite database
ActiveRecord::Base.establish_connection(
  adapter: "sqlite3",
  database: ":memory:"
)

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

  scope :active_authors, -> { where(active: true) }
end

class Post < ActiveRecord::Base
  belongs_to :user
  has_many :categorizations
  has_many :categories, through: :categorizations

  scope :published, -> { where(published: true) }
  scope :high_score, -> { where("score > 50") }
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
  config.example_status_persistence_file_path = ".rspec_status"

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
