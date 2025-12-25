# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Thread-safe `AggregationCache` class using `Monitor` for concurrent access safety
- Configuration module with customizable options:
  - `logger` - Set a custom logger (defaults to Rails.logger if available)
  - `log_level` - Set logging level (default: `:debug`)
  - `default_nil_value_for_sum` - Value returned for sum when no records match (default: `0`)
- `RecordExtension` module adding helper methods to ActiveRecord::Base:
  - `clear_aggregation_cache!` - Clear cached aggregation values for a record
  - `aggregation_cache_size` - Get the number of cached aggregations
  - `aggregation_cache_enabled?` - Check if eager aggregation caching is enabled
- Support for custom primary keys (non-integer IDs)
- Support for `count` with column argument to count only non-null values
- Improved logging via `Activerecord::Eager::Aggregation.log`

### Changed

- Refactored `CalculationInterceptor` to extract methods for better maintainability:
  - `build_cache_key` - Generates stable cache keys
  - `apply_additional_predicates` - Handles WHERE clause filtering
  - `execute_grouped_aggregation` - Performs the actual GROUP BY query
  - `default_aggregation_value` - Returns appropriate defaults for each aggregation type

### Fixed

- Removed debug `puts` statements from production code
- Improved cache key stability for scoped queries

## [0.1.0] - 2024-01-01

### Added

- Initial release
- `eager_aggregations` method for ActiveRecord relations
- Support for `count`, `sum`, `average`, `maximum`, `minimum` aggregations
- Batch fetching using GROUP BY to eliminate N+1 queries
- Support for `has_many` and `has_many :through` associations
- Support for scoped associations (e.g., `user.posts.published.count`)
