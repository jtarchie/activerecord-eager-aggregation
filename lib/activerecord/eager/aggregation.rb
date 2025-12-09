# frozen_string_literal: true

require_relative "aggregation/version"
require "active_record"

module Activerecord
  module Eager
    module Aggregation
      class Error < StandardError; end

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

      # Module to hook into record loading
      module RelationExtension
        def load
          result = super
          preload_aggregations if @values[:eager_aggregations] && loaded? && @records.any?
          result
        end

        private

        def preload_aggregations
          # Store aggregation cache on each record
          # Only initialize if not already present
          @records.each do |record|
            unless record.instance_variable_defined?(:@aggregation_cache)
              record.instance_variable_set(:@aggregation_cache, {})
            end
          end
        end
      end

      # Module to intercept calculation methods on relations
      # This works for both CollectionProxy and scoped relations
      module CalculationInterceptor
        [:count, :sum, :average, :maximum, :minimum].each do |method|
          define_method(method) do |*args, &block|
            # Check if this relation has an association (meaning it came from a has_many/belongs_to)
            if instance_variable_defined?(:@association)
              association = instance_variable_get(:@association)
              record_owner = association.owner

              if record_owner.instance_variable_defined?(:@aggregation_cache)
                # Build a stable cache key from the where clause predicates
                # Convert predicates to a stable string representation
                predicates = where_clause.send(:predicates)
                scope_key = predicates.map do |pred|
                  # For each predicate, create a stable representation
                  # Use the SQL of the predicate's components to avoid object_id issues
                  if pred.respond_to?(:left) && pred.respond_to?(:right)
                    "#{pred.class.name}:#{pred.left.name rescue pred.left.to_s}:#{pred.right.class.name}"
                  else
                    pred.class.name
                  end
                end.sort.join("|")

                cache_key = [association.reflection.name, method, args, scope_key].hash
                cache = record_owner.instance_variable_get(:@aggregation_cache)

                if cache.key?(cache_key)
                  return cache[cache_key]
                end

                # Fetch and cache
                result = super(*args, &block)
                cache[cache_key] = result
                return result
              end
            end

            super(*args, &block)
          end
        end
      end
    end
  end
end

# Extend ActiveRecord with our modules
module ActiveRecord
  class Base
    class << self
      delegate :eager_aggregations, to: :all
    end
  end
end

ActiveRecord::Relation.include(Activerecord::Eager::Aggregation::QueryMethods)
ActiveRecord::Relation.prepend(Activerecord::Eager::Aggregation::RelationExtension)
ActiveRecord::Relation.prepend(Activerecord::Eager::Aggregation::CalculationInterceptor)


ActiveRecord::Relation.include(Activerecord::Eager::Aggregation::QueryMethods)
ActiveRecord::Relation.prepend(Activerecord::Eager::Aggregation::RelationExtension)

# Use a different strategy: prepend to Relation to intercept calculation methods
# This works for both regular relations and scoped collection proxies
module Activerecord::Eager::Aggregation::CalculationInterceptor
  [:count, :sum, :average, :maximum, :minimum].each do |method|
    define_method(method) do |*args, &block|
      # Check if this relation has an association (meaning it came from a has_many/belongs_to)
      if instance_variable_defined?(:@association)
        association = instance_variable_get(:@association)
        record_owner = association.owner

        if record_owner.instance_variable_defined?(:@aggregation_cache)
          # Build a stable cache key from the where clause predicates
          # Convert predicates to a stable string representation
          predicates = where_clause.send(:predicates)
          scope_key = predicates.map do |pred|
            # For each predicate, create a stable representation
            # Use the SQL of the predicate's components to avoid object_id issues
            if pred.respond_to?(:left) && pred.respond_to?(:right)
              "#{pred.class.name}:#{pred.left.name rescue pred.left.to_s}:#{pred.right.class.name}"
            else
              pred.class.name
            end
          end.sort.join("|")

          cache_key = [association.reflection.name, method, args, scope_key].hash
          cache = record_owner.instance_variable_get(:@aggregation_cache)

          if cache.key?(cache_key)
            return cache[cache_key]
          end

          # Fetch and cache
          result = super(*args, &block)
          cache[cache_key] = result
          return result
        end
      end

      super(*args, &block)
    end
  end
end

ActiveRecord::Relation.prepend(Activerecord::Eager::Aggregation::CalculationInterceptor)
