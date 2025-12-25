# frozen_string_literal: true

RSpec.describe Activerecord::Eager::Aggregation do
  it 'has a version number' do
    expect(Activerecord::Eager::Aggregation::VERSION).not_to be nil
  end

  describe 'Configuration' do
    after do
      Activerecord::Eager::Aggregation.reset_configuration!
    end

    it 'has default configuration values' do
      config = Activerecord::Eager::Aggregation.configuration
      expect(config.logger).to be_nil
      expect(config.log_level).to eq(:debug)
      expect(config.default_nil_value_for_sum).to eq(0)
    end

    it 'allows configuration via block' do
      custom_logger = double('logger')
      Activerecord::Eager::Aggregation.configure do |config|
        config.logger = custom_logger
        config.log_level = :info
        config.default_nil_value_for_sum = nil
      end

      config = Activerecord::Eager::Aggregation.configuration
      expect(config.logger).to eq(custom_logger)
      expect(config.log_level).to eq(:info)
      expect(config.default_nil_value_for_sum).to be_nil
    end

    it 'can reset configuration' do
      Activerecord::Eager::Aggregation.configure do |config|
        config.log_level = :warn
      end

      Activerecord::Eager::Aggregation.reset_configuration!

      expect(Activerecord::Eager::Aggregation.configuration.log_level).to eq(:debug)
    end
  end

  describe 'AggregationCache' do
    let(:cache) { Activerecord::Eager::Aggregation::AggregationCache.new }

    it 'stores and retrieves values' do
      cache[:key1] = 100
      expect(cache[:key1]).to eq(100)
    end

    it 'checks for key existence' do
      cache[:key1] = 100
      expect(cache.key?(:key1)).to be true
      expect(cache.key?(:key2)).to be false
    end

    it 'clears all cached values' do
      cache[:key1] = 100
      cache[:key2] = 200
      cache.clear
      expect(cache.size).to eq(0)
    end

    it 'returns size' do
      cache[:key1] = 100
      cache[:key2] = 200
      expect(cache.size).to eq(2)
    end

    it 'returns hash copy' do
      cache[:key1] = 100
      hash = cache.to_h
      expect(hash).to eq({ key1: 100 })
      # Modifying returned hash shouldn't affect cache
      hash[:key2] = 200
      expect(cache.key?(:key2)).to be false
    end

    it 'uses fetch with block for missing keys' do
      result = cache.fetch(:missing, 42)
      expect(result).to eq(42)
    end

    it 'returns cached value in fetch without calling block' do
      cache[:existing] = 100
      block_called = false
      result = cache.fetch(:existing) do
        block_called = true
        42
      end
      expect(result).to eq(100)
      expect(block_called).to be false
    end

    context 'thread safety' do
      it 'handles concurrent access safely' do
        threads = 10.times.map do |i|
          Thread.new do
            100.times do |j|
              cache["thread_#{i}_#{j}".to_sym] = i * j
              cache["thread_#{i}_#{j}".to_sym]
            end
          end
        end

        expect { threads.each(&:join) }.not_to raise_error
        expect(cache.size).to eq(1000)
      end
    end
  end

  describe 'RecordExtension' do
    it 'provides clear_aggregation_cache! method' do
      user = User.create!(name: 'Alice')
      Post.create!(user: user)

      users = User.eager_aggregations.all
      users.first.posts.count

      expect(users.first.aggregation_cache_size).to be > 0
      users.first.clear_aggregation_cache!
      expect(users.first.aggregation_cache_size).to eq(0)
    end

    it 'provides aggregation_cache_enabled? method' do
      user = User.create!(name: 'Alice')

      expect(user.aggregation_cache_enabled?).to be false

      users = User.eager_aggregations.all
      expect(users.first.aggregation_cache_enabled?).to be true
    end

    it 'provides aggregation_cache_size method' do
      user = User.create!(name: 'Alice')
      Post.create!(user: user, score: 10)

      users = User.eager_aggregations.all
      expect(users.first.aggregation_cache_size).to eq(0)

      users.first.posts.count
      expect(users.first.aggregation_cache_size).to eq(1)

      users.first.posts.sum(:score)
      expect(users.first.aggregation_cache_size).to eq(2)
    end
  end

  describe '.eager_aggregations' do
    context 'basic count aggregation' do
      before do
        @user1 = User.create!(name: 'Alice')
        @user2 = User.create!(name: 'Bob')
        @user3 = User.create!(name: 'Charlie')

        3.times { Post.create!(user: @user1, title: 'Post') }
        2.times { Post.create!(user: @user2, title: 'Post') }
        # user3 has no posts
      end

      it 'triggers N+1 queries without eager_aggregations' do
        users = User.all

        # 1 for users, then 1 for each user's posts
        expect do
          users.each do |user|
            user.posts.count
          end
        end.to exceed_query_limit(3)
      end

      it 'reduces queries with eager_aggregations (lazy caching)' do
        users = User.eager_aggregations.all

        # 1 for users, 1 for first aggregations
        expect do
          # First call triggers queries, subsequent calls use cache
          users.each do |user|
            user.posts.count
            user.posts.count # Second access uses cache - no query
          end
        end.not_to exceed_query_limit(2)
      end

      it 'returns correct counts' do
        users = User.eager_aggregations.all.sort_by(&:name)

        expect(users[0].posts.count).to eq(3) # Alice
        expect(users[1].posts.count).to eq(2) # Bob
        expect(users[2].posts.count).to eq(0) # Charlie
      end
    end

    context 'filtering and scopes' do
      before do
        @user = User.create!(name: 'Alice')

        # Create posts with different states
        3.times { Post.create!(user: @user, published: true, score: 10) }
        2.times { Post.create!(user: @user, published: true, score: 60) }
        4.times { Post.create!(user: @user, published: false, score: 30) }
      end

      it 'triggers N+1 queries with scopes without eager_aggregations' do
        users = User.all

        # 1 for users, then multiple for scopes
        expect do
          users.each do |user|
            user.posts.published.count
            user.posts.high_score.count
          end
        end.to exceed_query_limit(2)
      end

      it 'reduces queries with scopes using eager_aggregations (lazy caching)' do
        users = User.eager_aggregations.all

        # 1 for users, 2 for first scoped aggregations (then cached)
        expect do
          # First iteration triggers queries
          users.each do |user|
            user.posts.published.count
            user.posts.high_score.count
            # Second iteration uses cache
            user.posts.published.count
            user.posts.high_score.count
          end
        end.not_to exceed_query_limit(3)
      end

      it 'returns correct scoped counts' do
        users = User.eager_aggregations.all

        user = users.first
        expect(user.posts.published.count).to eq(5)
        expect(user.posts.high_score.count).to eq(2)
      end
    end

    context 'aggregation functions' do
      before do
        @user1 = User.create!(name: 'Alice')
        @user2 = User.create!(name: 'Bob')

        Post.create!(user: @user1, score: 10)
        Post.create!(user: @user1, score: 20)
        Post.create!(user: @user1, score: 30)

        Post.create!(user: @user2, score: 50)
        Post.create!(user: @user2, score: 100)
      end

      it 'triggers N+1 queries for sum without eager_aggregations' do
        users = User.all

        expect do
          users.each do |user|
            user.posts.sum(:score)
          end
        end.to exceed_query_limit(2)
      end

      it 'reduces queries for sum with eager_aggregations (lazy caching)' do
        users = User.eager_aggregations.all

        # 1 for users, 1 for first sum calls (then cached)
        expect do
          users.each do |user|
            user.posts.sum(:score)
            # Second call uses cache
            user.posts.sum(:score)
          end
        end.not_to exceed_query_limit(2)
      end

      it 'returns correct sum values' do
        users = User.eager_aggregations.all.sort_by(&:name)

        expect(users[0].posts.sum(:score)).to eq(60) # Alice: 10+20+30
        expect(users[1].posts.sum(:score)).to eq(150) # Bob: 50+100
      end

      it 'triggers N+1 queries for average without eager_aggregations' do
        users = User.all

        expect do
          users.each do |user|
            user.posts.average(:score)
          end
        end.to exceed_query_limit(2)
      end

      it 'reduces queries for average with eager_aggregations (lazy caching)' do
        users = User.eager_aggregations.all

        expect do
          users.each do |user|
            user.posts.average(:score)
            user.posts.average(:score)
          end
        end.not_to exceed_query_limit(2)
      end

      it 'returns correct average values' do
        users = User.eager_aggregations.all.sort_by(&:name)

        expect(users[0].posts.average(:score).to_f).to eq(20.0) # Alice: (10+20+30)/3
        expect(users[1].posts.average(:score).to_f).to eq(75.0) # Bob: (50+100)/2
      end

      it 'triggers N+1 queries for maximum without eager_aggregations' do
        users = User.all

        expect do
          users.each do |user|
            user.posts.maximum(:score)
          end
        end.to exceed_query_limit(2)
      end

      it 'reduces queries for maximum with eager_aggregations (lazy caching)' do
        users = User.eager_aggregations.all

        expect do
          users.each do |user|
            user.posts.maximum(:score)
            user.posts.maximum(:score)
          end
        end.not_to exceed_query_limit(2)
      end

      it 'returns correct maximum values' do
        users = User.eager_aggregations.all.sort_by(&:name)

        expect(users[0].posts.maximum(:score)).to eq(30) # Alice
        expect(users[1].posts.maximum(:score)).to eq(100) # Bob
      end

      it 'triggers N+1 queries for minimum without eager_aggregations' do
        users = User.all

        expect do
          users.each do |user|
            user.posts.minimum(:score)
          end
        end.to exceed_query_limit(2)
      end

      it 'reduces queries for minimum with eager_aggregations (lazy caching)' do
        users = User.eager_aggregations.all

        expect do
          users.each do |user|
            user.posts.minimum(:score)
            user.posts.minimum(:score)
          end
        end.not_to exceed_query_limit(2)
      end

      it 'returns correct minimum values' do
        users = User.eager_aggregations.all.sort_by(&:name)

        expect(users[0].posts.minimum(:score)).to eq(10) # Alice
        expect(users[1].posts.minimum(:score)).to eq(50) # Bob
      end
    end

    context 'has_many :through associations' do
      before do
        @user1 = User.create!(name: 'Alice')
        @user2 = User.create!(name: 'Bob')

        @category1 = Category.create!(name: 'Tech', active: true)
        @category2 = Category.create!(name: 'Food', active: false)
        @category3 = Category.create!(name: 'Travel', active: true)

        post1 = Post.create!(user: @user1)
        post2 = Post.create!(user: @user1)
        post3 = Post.create!(user: @user2)

        Categorization.create!(post: post1, category: @category1)
        Categorization.create!(post: post1, category: @category2)
        Categorization.create!(post: post2, category: @category3)
        Categorization.create!(post: post3, category: @category1)
      end

      it 'triggers N+1 queries without eager_aggregations' do
        users = User.all

        expect do
          users.each do |user|
            user.categories.count
          end
        end.to exceed_query_limit(2)
      end

      it 'reduces queries with eager_aggregations (lazy caching)' do
        users = User.eager_aggregations.all

        expect do
          users.each do |user|
            user.categories.count
            user.categories.count
          end
        end.not_to exceed_query_limit(2)
      end

      it 'returns correct counts for has_many :through' do
        users = User.eager_aggregations.all.sort_by(&:name)

        expect(users[0].categories.count).to eq(3) # Alice has 3 categories
        expect(users[1].categories.count).to eq(1) # Bob has 1 category
      end

      it 'handles scoped has_many :through' do
        users = User.eager_aggregations.all.sort_by(&:name)

        expect(users[0].categories.active.count).to eq(2) # Alice has 2 active
        expect(users[1].categories.active.count).to eq(1) # Bob has 1 active
      end
    end

    context 'edge cases' do
      it 'handles empty collections' do
        users = User.eager_aggregations.all

        expect(users).to be_empty
      end

      it 'handles records with no associations' do
        User.create!(name: 'Alice')
        users = User.eager_aggregations.all

        expect(users.first.posts.count).to eq(0)
      end

      it 'handles multiple aggregations on same association' do
        user = User.create!(name: 'Alice')
        Post.create!(user: user, score: 10)
        Post.create!(user: user, score: 20)

        users = User.eager_aggregations.all

        # 1 for users, 3 for first aggregations (then cached)
        expect do
          users.each do |u|
            u.posts.count
            u.posts.sum(:score)
            u.posts.average(:score)
            # Second iteration uses cache
            u.posts.count
            u.posts.sum(:score)
            u.posts.average(:score)
          end
        end.not_to exceed_query_limit(4)
      end

      it 'handles nil values in aggregations' do
        user = User.create!(name: 'Alice')
        Post.create!(user: user, score: nil)
        Post.create!(user: user, score: 10)
        Post.create!(user: user, score: nil)

        users = User.eager_aggregations.all

        expect(users.first.posts.count).to eq(3)
        expect(users.first.posts.sum(:score)).to eq(10)
        expect(users.first.posts.average(:score).to_f).to eq(10.0)
        expect(users.first.posts.maximum(:score)).to eq(10)
        expect(users.first.posts.minimum(:score)).to eq(10)
      end

      it 'returns 0 for sum with no matching records by default' do
        User.create!(name: 'Alice')
        # No posts

        users = User.eager_aggregations.all

        expect(users.first.posts.sum(:score)).to eq(0)
      end

      it 'returns nil for max/min/average with no matching records' do
        User.create!(name: 'Alice')
        # No posts

        users = User.eager_aggregations.all

        expect(users.first.posts.maximum(:score)).to be_nil
        expect(users.first.posts.minimum(:score)).to be_nil
        expect(users.first.posts.average(:score)).to be_nil
      end
    end

    context 'count with column argument' do
      before do
        @user = User.create!(name: 'Alice')
        Post.create!(user: @user, score: 10)
        Post.create!(user: @user, score: nil)
        Post.create!(user: @user, score: 20)
      end

      it 'counts only non-null values when column specified' do
        users = User.eager_aggregations.all

        # count(:score) should only count non-nil values
        expect(users.first.posts.count(:score)).to eq(2)
        # count without argument counts all rows
        expect(users.first.posts.count).to eq(3)
      end
    end

    context 'single record optimization' do
      it 'works correctly with a single record' do
        user = User.create!(name: 'Alice')
        Post.create!(user: user, score: 10)
        Post.create!(user: user, score: 20)

        users = User.eager_aggregations.where(id: user.id)

        expect(users.first.posts.count).to eq(2)
        expect(users.first.posts.sum(:score)).to eq(30)
      end
    end

    context 'chaining with other ActiveRecord methods' do
      before do
        @user1 = User.create!(name: 'Alice', active: true)
        @user2 = User.create!(name: 'Bob', active: true)
        @user3 = User.create!(name: 'Charlie', active: false)

        2.times { Post.create!(user: @user1) }
        3.times { Post.create!(user: @user2) }
        Post.create!(user: @user3)
      end

      it 'works with where clauses' do
        users = User.eager_aggregations.where(active: true).order(:name)

        expect(users.size).to eq(2)
        expect(users[0].posts.count).to eq(2) # Alice
        expect(users[1].posts.count).to eq(3) # Bob
      end

      it 'works with limit' do
        users = User.eager_aggregations.order(:name).limit(2)

        expect(users.size).to eq(2)
        expect(users[0].posts.count).to eq(2) # Alice
        expect(users[1].posts.count).to eq(3) # Bob
      end

      it 'works with includes' do
        users = User.eager_aggregations.includes(:posts).order(:name)

        expect(users[0].posts.count).to eq(2)
        expect(users[1].posts.count).to eq(3)
      end
    end

    context 'polymorphic associations' do
      # NOTE: Polymorphic associations require special handling
      # This test documents current behavior
      it 'handles standard associations correctly when polymorphic exists' do
        user = User.create!(name: 'Alice')
        Post.create!(user: user)

        users = User.eager_aggregations.all
        expect(users.first.posts.count).to eq(1)
      end
    end

    context 'large dataset performance' do
      it 'efficiently handles many records' do
        # Create 50 users with varying post counts
        50.times do |i|
          user = User.create!(name: "User#{i}")
          (i % 5).times { Post.create!(user: user, score: i) }
        end

        users = User.eager_aggregations.all

        # Should only be 2 queries: 1 for users, 1 for count
        expect do
          users.each { |u| u.posts.count }
        end.not_to exceed_query_limit(2)

        # Verify correct counts
        expect(users.find { |u| u.name == 'User0' }.posts.count).to eq(0)
        expect(users.find { |u| u.name == 'User4' }.posts.count).to eq(4)
        expect(users.find { |u| u.name == 'User49' }.posts.count).to eq(4)
      end
    end
  end
end
