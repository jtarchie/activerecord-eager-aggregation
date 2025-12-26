# frozen_string_literal: true

require_relative 'aggregation/version'
require 'active_record'
require 'monitor'

module Activerecord
  module Eager
    module Aggregation
      class Error < StandardError; end

      # Configuration for the gem
      class Configuration
        attr_accessor :logger, :log_level, :default_nil_value_for_sum

        def initialize
          @logger = nil # Will use Rails.logger if available, or nil for no logging
          @log_level = :debug
          @default_nil_value_for_sum = 0 # Return 0 instead of nil for sum when no records
        end

        def effective_logger
          @logger || (defined?(Rails) && Rails.respond_to?(:logger) ? Rails.logger : nil)
        end
      end

      class << self
        def configuration
          @configuration ||= Configuration.new
        end

        def configure
          yield(configuration)
        end

        def reset_configuration!
          @configuration = Configuration.new
        end

        def log(message, level: configuration.log_level)
          logger = configuration.effective_logger
          return unless logger

          logger.public_send(level, "[EagerAggregation] #{message}")
        end
      end

      # Thread-safe cache wrapper for storing aggregation results
      class AggregationCache
        def initialize
          @cache = {}
          @monitor = Monitor.new
        end

        def fetch(key, default = nil)
          @monitor.synchronize do
            return @cache[key] if @cache.key?(key)

            if block_given?
              yield
            else
              default
            end
          end
        end

        def key?(key)
          @monitor.synchronize { @cache.key?(key) }
        end

        def [](key)
          @monitor.synchronize { @cache[key] }
        end

        def []=(key, value)
          @monitor.synchronize { @cache[key] = value }
        end

        def clear
          @monitor.synchronize { @cache.clear }
        end

        def size
          @monitor.synchronize { @cache.size }
        end

        def to_h
          @monitor.synchronize { @cache.dup }
        end
      end

      # Module to extend ActiveRecord::Relation with eager_aggregations
      module QueryMethods
        def eager_aggregations
          spawn.tap { |relation| relation.eager_aggregations_value = true }
        end

        def eager_aggregations_value=(value)
          @values[:eager_aggregations] = value
        end

        def eager_aggregations_enabled?
          @values[:eager_aggregations] || false
        end
      end

      # Module to add cache management methods to ActiveRecord::Base
      module RecordExtension
        def clear_aggregation_cache!
          return unless instance_variable_defined?(:@aggregation_cache)

          cache = instance_variable_get(:@aggregation_cache)
          cache.clear if cache.respond_to?(:clear)
        end

        def aggregation_cache_size
          return 0 unless instance_variable_defined?(:@aggregation_cache)

          cache = instance_variable_get(:@aggregation_cache)
          cache.respond_to?(:size) ? cache.size : 0
        end

        def aggregation_cache_enabled?
          instance_variable_defined?(:@aggregation_cache)
        end
      end

      # Module to hook into record loading
      module RelationExtension
        def load
          result = super
          preload_aggregations if @values[:eager_aggregations] && loaded? && @records.any?
          result
        end

        private

        def preload_aggregations
          Aggregation.log("Enabling eager aggregations for #{@records.size} #{klass.name} records")

          # Store aggregation cache on each record
          # Only initialize if not already present
          # Also store a reference to all loaded records for batch queries
          @records.each do |record|
            unless record.instance_variable_defined?(:@aggregation_cache)
              record.instance_variable_set(:@aggregation_cache, AggregationCache.new)
            end
            # Store reference to all batch owners for GROUP BY queries
            record.instance_variable_set(:@aggregation_batch_owners, @records)
          end
        end
      end

      # Module to intercept calculation methods on relations
      # This works for both CollectionProxy and scoped relations
      module CalculationInterceptor
        AGGREGATION_METHODS = %i[count sum average maximum minimum].freeze

        AGGREGATION_METHODS.each do |method|
          define_method(method) do |*args, &block|
            # Check if this relation has an association (meaning it came from a has_many/belongs_to)
            if instance_variable_defined?(:@association)
              association = instance_variable_get(:@association)
              record_owner = association.owner

              if record_owner.instance_variable_defined?(:@aggregation_cache)
                cache_key = build_cache_key(association, method, args)
                cache = record_owner.instance_variable_get(:@aggregation_cache)

                if cache.key?(cache_key)
                  Aggregation.log("Cache hit for #{method} on #{association.reflection.name}")
                  return cache[cache_key]
                end

                # Try to batch fetch aggregations for all records using GROUP BY
                all_owners = record_owner.instance_variable_get(:@aggregation_batch_owners)

                if all_owners && all_owners.size > 1
                  # Batch fetch for multiple owners
                  Aggregation.log("Batch fetching #{method} for #{all_owners.size} owners")
                  batch_fetch_aggregations_for_all(association, method, args, cache_key, all_owners)
                  # Return the cached value for this specific record
                  return cache[cache_key] if cache.key?(cache_key)
                end

                # Single record or fallback - fetch individually and cache
                Aggregation.log("Individual fetch for #{method} on #{association.reflection.name}")
                result = super(*args, &block)
                cache[cache_key] = result
                return result
              end
            end

            super(*args, &block)
          end
        end

        private

        def build_cache_key(association, method, args)
          # Build a stable cache key from the where clause predicates
          # Convert predicates to a stable string representation
          predicates = where_clause.send(:predicates)
          scope_key = predicates.map do |pred|
            # For each predicate, create a stable representation
            # Use the SQL of the predicate's components to avoid object_id issues
            if pred.respond_to?(:left) && pred.respond_to?(:right)
              left_name = pred.left.respond_to?(:name) ? pred.left.name : pred.left.to_s
              "#{pred.class.name}:#{left_name}:#{pred.right.class.name}"
            else
              pred.class.name
            end
          end.sort.join('|')

          [association.reflection.name, method, args, scope_key].hash
        end

        def batch_fetch_aggregations_for_all(association, method, args, _cache_key_template, all_owners)
          reflection = association.reflection
          owner_key_attribute = reflection.active_record.primary_key
          owner_ids = all_owners.map { |owner| owner.public_send(owner_key_attribute) }

          # Build the base query
          if reflection.through_reflection
            # For has_many :through, let ActiveRecord handle the joins
            through_reflection = reflection.through_reflection
            owner_foreign_key = "#{through_reflection.table_name}.#{through_reflection.foreign_key}"
            unscope_key = through_reflection.foreign_key.to_sym

            # Start with the klass and let merge() add the joins from association scope
          else
            # For regular has_many
            owner_foreign_key = reflection.foreign_key
            unscope_key = reflection.foreign_key.to_sym
          end
          base_query = reflection.klass.where(owner_foreign_key => owner_ids)

          # Merge the scope from the association, but unscope the owner foreign key
          # to avoid overwriting our IN clause with a single owner's WHERE clause
          association_scope = association.scope.unscope(where: unscope_key)
          base_query = base_query.merge(association_scope.unscope(:select))

          # Apply any additional WHERE clauses from the current relation (e.g., .active)
          base_query = apply_additional_predicates(base_query, unscope_key)

          # Perform the aggregation with GROUP BY
          results = execute_grouped_aggregation(base_query, owner_foreign_key, method, args)

          Aggregation.log("Batch query returned #{results.size} results for #{all_owners.size} owners")

          # Extract scope_key from cache_key_template for rebuilding cache keys
          predicates = where_clause.send(:predicates)
          scope_key = predicates.map do |pred|
            if pred.respond_to?(:left) && pred.respond_to?(:right)
              left_name = pred.left.respond_to?(:name) ? pred.left.name : pred.left.to_s
              "#{pred.class.name}:#{left_name}:#{pred.right.class.name}"
            else
              pred.class.name
            end
          end.sort.join('|')

          # Cache results for all owners
          default_value = default_aggregation_value(method)
          all_owners.each do |owner|
            owner_cache = owner.instance_variable_get(:@aggregation_cache)
            owner_id = owner.public_send(owner_key_attribute)
            owner_cache_key = [reflection.name, method, args, scope_key].hash
            owner_cache[owner_cache_key] = results[owner_id] || default_value
          end
        end

        def apply_additional_predicates(base_query, unscope_key)
          # Apply any additional WHERE clauses from the current relation (e.g., .active)
          # We need to preserve predicates from the chained scope (like .active)
          # but exclude the owner foreign key predicate which we handle separately
          relation_where = where_clause
          return base_query if relation_where.empty?

          # Get the AST (predicates) from the current relation's where clause
          predicates = relation_where.send(:predicates).reject do |pred|
            # Skip predicates on the owner foreign key (already handled by our IN clause)
            pred.respond_to?(:left) &&
              pred.left.respond_to?(:name) &&
              pred.left.name.to_s == unscope_key.to_s
          end

          # Apply filtered predicates by merging them into the query
          predicates.each do |predicate|
            base_query = base_query.where(predicate)
          end

          base_query
        end

        def execute_grouped_aggregation(base_query, group_key, method, args)
          case method
          when :count
            # Handle DISTINCT counts: count(:column_name, distinct: true)
            if args.length >= 2 && args[1].is_a?(Hash) && args[1][:distinct]
              base_query.group(group_key).distinct.count(args.first)
            elsif args.first && args.first != :all
              base_query.group(group_key).count(args.first)
            else
              base_query.group(group_key).count
            end
          when :sum
            base_query.group(group_key).sum(args.first)
          when :average
            base_query.group(group_key).average(args.first)
          when :maximum
            base_query.group(group_key).maximum(args.first)
          when :minimum
            base_query.group(group_key).minimum(args.first)
          end
        end

        def default_aggregation_value(method)
          case method
          when :count
            0
          when :sum
            Aggregation.configuration.default_nil_value_for_sum
          end
        end
      end
    end
  end
end

# Extend ActiveRecord with our modules
module ActiveRecord
  class Base
    include Activerecord::Eager::Aggregation::RecordExtension

    class << self
      delegate :eager_aggregations, to: :all
    end
  end
end

ActiveRecord::Relation.include(Activerecord::Eager::Aggregation::QueryMethods)
ActiveRecord::Relation.prepend(Activerecord::Eager::Aggregation::RelationExtension)
ActiveRecord::Relation.prepend(Activerecord::Eager::Aggregation::CalculationInterceptor)
