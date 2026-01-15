# ActiveRecord::Eager::Aggregation

ActiveRecord makes it easy to work with associations, but it can lead to
performance issues when dealing with aggregations in a loop. For example,
calling `user.posts.count` for each user in a list will trigger a separate
database query for every user (an N+1 query problem). This gem solves this by
allowing you to eager-load these aggregations in a constant number of queries.

## Installation

Install the gem and add to the application's Gemfile by executing:

```bash
bundle add activerecord-eager-aggregation
```

If bundler is not being used to manage dependencies, install the gem by
executing:

```bash
gem install "activerecord-eager-aggregation"
```

## Usage

To start eager-loading aggregations, simply add `.eager_aggregations` to your
ActiveRecord relation. When you later access an aggregation on a `has_many`
association for an individual record, the value will be returned from a
pre-loaded cache instead of hitting the database again.

```ruby
# Before: N+1 queries
# This code runs a query for each user to count their posts.
users = User.all
users.each do |user|
  puts "#{user.name} has #{user.posts.count} posts."
end

# After: 2 queries
# This code runs one query for the users, and one query to get the post counts for all users.
users = User.eager_aggregations.all
users.each do |user|
  # This does not trigger a new query
  puts "#{user.name} has #{user.posts.count} posts."
end
```

## Examples

### Filtering and Scopes

You can chain `where` clauses and scopes on the association before calling the
aggregation. Each unique combination of scopes will be fetched in a separate
eager query.

```ruby
users = User.active_authors.eager_aggregations
users.each do |user|
  # These are all loaded efficiently
  puts "Published posts: #{user.posts.published.count}"
  puts "High score posts: #{user.posts.high_score.count}"
end
```

### Supported Aggregation Functions

The gem supports `count`, `sum`, `average`, `maximum`, and `minimum`.

```ruby
users = User.eager_aggregations.all
users.each do |user|
  puts "Total score: #{user.posts.sum(:score)}"
  puts "Average score: #{user.posts.average(:score)}"
  puts "Max score: #{user.posts.maximum(:score)}"
  puts "Min score: #{user.posts.minimum(:score)}"
end
```

### `has_many :through` Associations

It also works seamlessly with `has_many :through` associations.

```ruby
users = User.eager_aggregations.all
users.each do |user|
  puts "Total categories: #{user.categories.count}"
  puts "Active categories: #{user.categories.active.count}"
end
```

### Associations with Built-in Scopes

If your association has a built-in scope (lambda), eager aggregations works
correctly with those as well.

```ruby
class User < ActiveRecord::Base
  has_many :posts
  has_many :published_posts, -> { where(published: true) }, class_name: 'Post'
  has_many :recent_posts, -> { order(created_at: :desc) }, class_name: 'Post'
end

users = User.eager_aggregations.all
users.each do |user|
  # Works with scoped associations
  puts "Published posts: #{user.published_posts.count}"
  puts "Recent posts: #{user.recent_posts.count}"
end
```

### Distinct Counts

You can count distinct column values using the standard ActiveRecord `.distinct`
method.

```ruby
users = User.eager_aggregations.all
users.each do |user|
  # Count distinct scores across all posts
  puts "Unique scores: #{user.posts.distinct.count(:score)}"
end
```

### Cache Management

Each record has a cache that stores aggregation results. You can inspect and
manage this cache:

```ruby
users = User.eager_aggregations.all
user = users.first

# Check if cache is enabled
user.aggregation_cache_enabled?  # => true

# Check cache size
user.aggregation_cache_size  # => 0

user.posts.count  # Populates cache
user.aggregation_cache_size  # => 1

# Clear the cache manually (useful after mutations)
user.clear_aggregation_cache!
user.aggregation_cache_size  # => 0
```

**Note:** The cache is not automatically invalidated when records are created,
updated, or deleted. If you modify associated records, either re-query with
`eager_aggregations` or call `clear_aggregation_cache!` on affected records.

## Configuration

You can configure the gem's behavior:

```ruby
Activerecord::Eager::Aggregation.configure do |config|
  # Set a logger for debugging (defaults to Rails.logger if available)
  config.logger = Rails.logger

  # Set log level for eager aggregation messages (default: :debug)
  config.log_level = :debug

  # Default value for sum when no records match (default: 0)
  # Set to nil to return nil instead of 0
  config.default_nil_value_for_sum = 0
end
```

## Development

After checking out the repo, run `bin/setup` to install dependencies. You can
also run `bin/console` for an interactive prompt that will allow you to
experiment.

### Running Tests

By default, tests run against SQLite in-memory:

```bash
bundle exec rspec
```

### Testing with PostgreSQL and MySQL

The gem is tested against SQLite, PostgreSQL, and MySQL. To run tests against
all databases:

```bash
# Start the database containers
bin/test-databases start

# Run tests against all databases
bin/test-databases test

# Or run against a specific database
DB=postgresql bundle exec rspec
DB=mysql bundle exec rspec
DB=sqlite bundle exec rspec

# Stop containers when done
bin/test-databases stop
```

To install this gem onto your local machine, run `bundle exec rake install`. To
release a new version, update the version number in `version.rb`, and then run
`bundle exec rake release`, which will create a git tag for the version, push
git commits and the created tag, and push the `.gem` file to
[rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at
https://github.com/jtarchie/activerecord-eager-aggregation. This project is
intended to be a safe, welcoming space for collaboration, and contributors are
expected to adhere to the
[code of conduct](https://github.com/jtarchie/activerecord-eager-aggregation/blob/main/CODE_OF_CONDUCT.md).

## License

The gem is available as open source under the terms of the
[MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the Activerecord::Eager::Aggregation project's
codebases, issue trackers, chat rooms and mailing lists is expected to follow
the
[code of conduct](https://github.com/jtarchie/activerecord-eager-aggregation/blob/main/CODE_OF_CONDUCT.md).

## Notes

These are examples of the current eager loading for associations in Rails source
code. They were used as inspiration.

- https://github.com/rails/rails/blob/main/activerecord/lib/active_record/associations/preloader.rb
- https://github.com/rails/rails/blob/main/activerecord/lib/active_record/associations/preloader/through_association.rb
- https://github.com/rails/rails/blob/main/activerecord/lib/active_record/associations/preloader/branch.rb
- https://github.com/rails/rails/blob/main/activerecord/lib/active_record/associations/preloader/batch.rb
- https://github.com/rails/rails/blob/main/activerecord/lib/active_record/associations/preloader/association.rb
- https://github.com/rails/rails/blob/main/activerecord/test/cases/associations/eager_test.rb
