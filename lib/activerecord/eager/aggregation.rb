# frozen_string_literal: true

require_relative 'aggregation/version'
require 'active_record'
require 'concurrent/map'

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
              record.instance_variable_set(:@aggregation_cache, Concurrent::Map.new)
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
                  batch_fetch_aggregations_for_all(association, method, args, all_owners)
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

        def distinct?
          respond_to?(:distinct_value) && distinct_value
        end

        def predicate_to_string(pred)
          if pred.respond_to?(:left) && pred.respond_to?(:right)
            left_name = pred.left.respond_to?(:name) ? pred.left.name : pred.left.to_s
            "#{pred.class.name}:#{left_name}:#{pred.right.class.name}"
          else
            pred.class.name
          end
        end

        def scope_key
          where_clause.send(:predicates).map { |p| predicate_to_string(p) }.sort.join('|')
        end

        def build_cache_key(association, method, args)
          [association.reflection.name, method, args, scope_key, distinct?].hash
        end

        def batch_fetch_aggregations_for_all(association, method, args, all_owners)
          reflection = association.reflection
          pk = reflection.active_record.primary_key
          owner_ids = all_owners.map { |owner| owner.public_send(pk) }

          fk, unscope_key = foreign_keys_for(reflection)
          base_query = build_aggregation_query(reflection, association, fk, unscope_key, owner_ids)
          results = execute_grouped_aggregation(base_query, fk, method, args)

          Aggregation.log("Batch query returned #{results.size} results for #{all_owners.size} owners")
          cache_results(reflection, method, args, all_owners, pk, results)
        end

        def foreign_keys_for(reflection)
          if reflection.through_reflection
            through = reflection.through_reflection
            ["#{through.table_name}.#{through.foreign_key}", through.foreign_key.to_sym]
          else
            [reflection.foreign_key, reflection.foreign_key.to_sym]
          end
        end

        def build_aggregation_query(reflection, association, fk, unscope_key, owner_ids)
          base = reflection.klass.where(fk => owner_ids)

          # Merge the scope from the association, but unscope the owner foreign key
          # to avoid overwriting our IN clause with a single owner's WHERE clause.
          # Also unscope ORDER BY since it conflicts with GROUP BY in strict SQL mode.
          association_scope = association.scope.unscope(where: unscope_key).unscope(:order).unscope(:select)
          merged = base.merge(association_scope)

          apply_additional_predicates(merged, unscope_key).unscope(:order)
        end

        def cache_results(reflection, method, args, all_owners, pk, results)
          default = default_value_for(method)
          key_base = [reflection.name, method, args, scope_key, distinct?]

          all_owners.each do |owner|
            cache = owner.instance_variable_get(:@aggregation_cache)
            cache[key_base.hash] = results[owner.public_send(pk)] || default
          end
        end

        def apply_additional_predicates(base_query, unscope_key)
          relation_where = where_clause
          return base_query if relation_where.empty?

          predicates = relation_where.send(:predicates).reject do |pred|
            pred.respond_to?(:left) &&
              pred.left.respond_to?(:name) &&
              pred.left.name.to_s == unscope_key.to_s
          end

          predicates.reduce(base_query) { |q, pred| q.where(pred) }
        end

        def execute_grouped_aggregation(base_query, group_key, method, args)
          grouped = base_query.group(group_key)
          column = args.first

          case method
          when :count
            return grouped.distinct.count(column) if distinct? && column && column != :all
            return grouped.count(column) if column && column != :all

            grouped.count
          when :sum      then grouped.sum(column)
          when :average  then grouped.average(column)
          when :maximum  then grouped.maximum(column)
          when :minimum  then grouped.minimum(column)
          end
        end

        def default_value_for(method)
          case method
          when :count then 0
          when :sum   then Aggregation.configuration.default_nil_value_for_sum
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
