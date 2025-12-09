# frozen_string_literal: true

RSpec.describe Activerecord::Eager::Aggregation do
  it "has a version number" do
    expect(Activerecord::Eager::Aggregation::VERSION).not_to be nil
  end

  describe ".eager_aggregations" do
    context "basic count aggregation" do
      before do
        @user1 = User.create!(name: "Alice")
        @user2 = User.create!(name: "Bob")
        @user3 = User.create!(name: "Charlie")

        3.times { Post.create!(user: @user1, title: "Post") }
        2.times { Post.create!(user: @user2, title: "Post") }
        # user3 has no posts
      end

      it "triggers N+1 queries without eager_aggregations" do
        users = User.all

        expect {
          users.each do |user|
            user.posts.count
          end
        }.to exceed_query_limit(3) # 1 for users, then 1 for each user's posts
      end

      it "reduces queries with eager_aggregations (lazy caching)" do
        users = User.eager_aggregations.all

        expect {
          # First call triggers queries, subsequent calls use cache
          users.each do |user|
            user.posts.count # First access triggers query
          end
          users.each do |user|
            user.posts.count # Second access uses cache - no query
          end
        }.not_to exceed_query_limit(4) # 1 for users, 3 for first aggregations
      end

      it "returns correct counts" do
        users = User.eager_aggregations.all.sort_by(&:name)

        expect(users[0].posts.count).to eq(3) # Alice
        expect(users[1].posts.count).to eq(2) # Bob
        expect(users[2].posts.count).to eq(0) # Charlie
      end
    end

    context "filtering and scopes" do
      before do
        @user = User.create!(name: "Alice")

        # Create posts with different states
        3.times { Post.create!(user: @user, published: true, score: 10) }
        2.times { Post.create!(user: @user, published: true, score: 60) }
        4.times { Post.create!(user: @user, published: false, score: 30) }
      end

      it "triggers N+1 queries with scopes without eager_aggregations" do
        users = User.all

        expect {
          users.each do |user|
            user.posts.published.count
            user.posts.high_score.count
          end
        }.to exceed_query_limit(2) # 1 for users, then multiple for scopes
      end

      it "reduces queries with scopes using eager_aggregations (lazy caching)" do
        users = User.eager_aggregations.all

        expect {
          # First iteration triggers queries
          users.each do |user|
            user.posts.published.count
            user.posts.high_score.count
          end
          # Second iteration uses cache
          users.each do |user|
            user.posts.published.count
            user.posts.high_score.count
          end
        }.not_to exceed_query_limit(3) # 1 for users, 2 for first scoped aggregations (then cached)
      end

      it "returns correct scoped counts" do
        users = User.eager_aggregations.all

        user = users.first
        expect(user.posts.published.count).to eq(5)
        expect(user.posts.high_score.count).to eq(2)
      end
    end

    context "aggregation functions" do
      before do
        @user1 = User.create!(name: "Alice")
        @user2 = User.create!(name: "Bob")

        Post.create!(user: @user1, score: 10)
        Post.create!(user: @user1, score: 20)
        Post.create!(user: @user1, score: 30)

        Post.create!(user: @user2, score: 50)
        Post.create!(user: @user2, score: 100)
      end

      it "triggers N+1 queries for sum without eager_aggregations" do
        users = User.all

        expect {
          users.each do |user|
            user.posts.sum(:score)
          end
        }.to exceed_query_limit(2)
      end

      it "reduces queries for sum with eager_aggregations (lazy caching)" do
        users = User.eager_aggregations.all

        expect {
          users.each do |user|
            user.posts.sum(:score)
          end
          # Second call uses cache
          users.each do |user|
            user.posts.sum(:score)
          end
        }.not_to exceed_query_limit(3) # 1 for users, 2 for first sum calls (then cached)
      end

      it "returns correct sum values" do
        users = User.eager_aggregations.all.sort_by(&:name)

        expect(users[0].posts.sum(:score)).to eq(60) # Alice: 10+20+30
        expect(users[1].posts.sum(:score)).to eq(150) # Bob: 50+100
      end

      it "triggers N+1 queries for average without eager_aggregations" do
        users = User.all

        expect {
          users.each do |user|
            user.posts.average(:score)
          end
        }.to exceed_query_limit(2)
      end

      it "reduces queries for average with eager_aggregations (lazy caching)" do
        users = User.eager_aggregations.all

        expect {
          users.each do |user|
            user.posts.average(:score)
          end
          users.each do |user|
            user.posts.average(:score)
          end
        }.not_to exceed_query_limit(3)
      end

      it "returns correct average values" do
        users = User.eager_aggregations.all.sort_by(&:name)

        expect(users[0].posts.average(:score).to_f).to eq(20.0) # Alice: (10+20+30)/3
        expect(users[1].posts.average(:score).to_f).to eq(75.0) # Bob: (50+100)/2
      end

      it "triggers N+1 queries for maximum without eager_aggregations" do
        users = User.all

        expect {
          users.each do |user|
            user.posts.maximum(:score)
          end
        }.to exceed_query_limit(2)
      end

      it "reduces queries for maximum with eager_aggregations (lazy caching)" do
        users = User.eager_aggregations.all

        expect {
          users.each do |user|
            user.posts.maximum(:score)
          end
          users.each do |user|
            user.posts.maximum(:score)
          end
        }.not_to exceed_query_limit(3)
      end

      it "returns correct maximum values" do
        users = User.eager_aggregations.all.sort_by(&:name)

        expect(users[0].posts.maximum(:score)).to eq(30) # Alice
        expect(users[1].posts.maximum(:score)).to eq(100) # Bob
      end

      it "triggers N+1 queries for minimum without eager_aggregations" do
        users = User.all

        expect {
          users.each do |user|
            user.posts.minimum(:score)
          end
        }.to exceed_query_limit(2)
      end

      it "reduces queries for minimum with eager_aggregations (lazy caching)" do
        users = User.eager_aggregations.all

        expect {
          users.each do |user|
            user.posts.minimum(:score)
          end
          users.each do |user|
            user.posts.minimum(:score)
          end
        }.not_to exceed_query_limit(3)
      end

      it "returns correct minimum values" do
        users = User.eager_aggregations.all.sort_by(&:name)

        expect(users[0].posts.minimum(:score)).to eq(10) # Alice
        expect(users[1].posts.minimum(:score)).to eq(50) # Bob
      end
    end

    context "has_many :through associations" do
      before do
        @user1 = User.create!(name: "Alice")
        @user2 = User.create!(name: "Bob")

        @category1 = Category.create!(name: "Tech", active: true)
        @category2 = Category.create!(name: "Food", active: false)
        @category3 = Category.create!(name: "Travel", active: true)

        post1 = Post.create!(user: @user1)
        post2 = Post.create!(user: @user1)
        post3 = Post.create!(user: @user2)

        Categorization.create!(post: post1, category: @category1)
        Categorization.create!(post: post1, category: @category2)
        Categorization.create!(post: post2, category: @category3)
        Categorization.create!(post: post3, category: @category1)
      end

      it "triggers N+1 queries without eager_aggregations" do
        users = User.all

        expect {
          users.each do |user|
            user.categories.count
          end
        }.to exceed_query_limit(2)
      end

      it "reduces queries with eager_aggregations (lazy caching)" do
        users = User.eager_aggregations.all

        expect {
          users.each do |user|
            user.categories.count
          end
          users.each do |user|
            user.categories.count
          end
        }.not_to exceed_query_limit(3)
      end

      it "returns correct counts for has_many :through" do
        users = User.eager_aggregations.all.sort_by(&:name)

        expect(users[0].categories.count).to eq(3) # Alice has 3 categories
        expect(users[1].categories.count).to eq(1) # Bob has 1 category
      end

      it "handles scoped has_many :through" do
        users = User.eager_aggregations.all.sort_by(&:name)

        expect(users[0].categories.active.count).to eq(2) # Alice has 2 active
        expect(users[1].categories.active.count).to eq(1) # Bob has 1 active
      end
    end

    context "edge cases" do
      it "handles empty collections" do
        users = User.eager_aggregations.all

        expect(users).to be_empty
      end

      it "handles records with no associations" do
        user = User.create!(name: "Alice")
        users = User.eager_aggregations.all

        expect(users.first.posts.count).to eq(0)
      end

      it "handles multiple aggregations on same association" do
        user = User.create!(name: "Alice")
        Post.create!(user: user, score: 10)
        Post.create!(user: user, score: 20)

        users = User.eager_aggregations.all

        expect {
          users.each do |u|
            u.posts.count
            u.posts.sum(:score)
            u.posts.average(:score)
          end
          # Second iteration uses cache
          users.each do |u|
            u.posts.count
            u.posts.sum(:score)
            u.posts.average(:score)
          end
        }.not_to exceed_query_limit(4) # 1 for users, 3 for first aggregations (then cached)
      end
    end
  end
end
