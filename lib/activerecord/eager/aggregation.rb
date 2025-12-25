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
          # Also store a reference to all loaded records for batch queries
          @records.each do |record|
            unless record.instance_variable_defined?(:@aggregation_cache)
              record.instance_variable_set(:@aggregation_cache, {})
            end
            # Store reference to all batch owners for GROUP BY queries
            record.instance_variable_set(:@aggregation_batch_owners, @records)
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

                # Try to batch fetch aggregations for all records using GROUP BY
                all_owners = record_owner.instance_variable_get(:@aggregation_batch_owners)

                if all_owners && all_owners.size > 1
                  # Batch fetch for multiple owners
                  batch_fetch_aggregations_for_all(association, method, args, scope_key, all_owners)
                  # Return the cached value for this specific record
                  if cache.key?(cache_key)
                    return cache[cache_key]
                  end
                end

                # Single record or fallback - fetch individually and cache
                result = super(*args, &block)
                cache[cache_key] = result
                return result
              end
            end

            super(*args, &block)
          end
        end

        private

        def batch_fetch_aggregations_for_all(association, method, args, scope_key, all_owners)
          reflection = association.reflection
          owner_ids = all_owners.map(&:id)

          # Build the base query
          if reflection.through_reflection
            # For has_many :through, let ActiveRecord handle the joins
            through_reflection = reflection.through_reflection
            owner_foreign_key = "#{through_reflection.table_name}.#{through_reflection.foreign_key}"
            unscope_key = through_reflection.foreign_key.to_sym

            # Start with the klass and let merge() add the joins from association scope
            base_query = reflection.klass.where(owner_foreign_key => owner_ids)
          else
            # For regular has_many
            owner_foreign_key = reflection.foreign_key
            unscope_key = reflection.foreign_key.to_sym
            base_query = reflection.klass.where(owner_foreign_key => owner_ids)
          end

          # Merge the scope from the association, but unscope the owner foreign key
          # to avoid overwriting our IN clause with a single owner's WHERE clause
          association_scope = association.scope.unscope(where: unscope_key)
          base_query = base_query.merge(association_scope.unscope(:select))

          # Apply any additional WHERE clauses from the current relation (e.g., .active)
          # We need to preserve predicates from the chained scope (like .active)
          # but exclude the owner foreign key predicate which we handle separately
          relation_where = where_clause
          unless relation_where.empty?
            # Get the AST (predicates) from the current relation's where clause
            predicates = relation_where.send(:predicates).reject do |pred|
              # Skip predicates on the owner foreign key (already handled by our IN clause)
              pred.respond_to?(:left) &&
                pred.left.respond_to?(:name) &&
                pred.left.name.to_s == unscope_key.to_s
            end

            # Apply filtered predicates by merging them into the query
            unless predicates.empty?
              predicates.each do |predicate|
                # Use the predicate's to_sql to extract the condition
                # This is a bit of a hack but works reliably
                base_query = base_query.where(predicate)
              end
            end
          end

          # Perform the aggregation with GROUP BY
          results = case method
          when :count
            base_query.group(owner_foreign_key).count
          when :sum
            base_query.group(owner_foreign_key).sum(args.first)
          when :average
            base_query.group(owner_foreign_key).average(args.first)
          when :maximum
            base_query.group(owner_foreign_key).maximum(args.first)
          when :minimum
            base_query.group(owner_foreign_key).minimum(args.first)
          end

          # Cache results for all owners
          all_owners.each do |owner|
            owner_cache = owner.instance_variable_get(:@aggregation_cache)
            owner_cache_key = [reflection.name, method, args, scope_key].hash
            owner_cache[owner_cache_key] = results[owner.id] || (method == :count ? 0 : nil)
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
