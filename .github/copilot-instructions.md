<!-- Copilot / Coding Agent Onboarding: activerecord-eager-aggregation -->

## Purpose

This file helps a coding agent (Copilot coding agent) quickly understand, build,
and validate changes for this repository so PRs are fast, reliable, and match CI
expectations.

## High-level summary

- What: A small Ruby gem that adds eager aggregation support to ActiveRecord
  relations, avoiding N+1 aggregation queries by preloading aggregation results.
- Project type: Ruby gem (library) targeting ActiveRecord users.
- Primary language: Ruby. Tests use RSpec. Small, focused repo (~50–200 files;
  actually very small here).

## Runtimes, versions, and CI

- Primary Ruby runtime: CI uses Ruby 3.4.3 (see workflow). The gemspec states
  `required_ruby_version = ">= 3.1.0"`.
- CI: GitHub Actions workflow at `.github/workflows/main.yml` runs
  `bundle exec rake` on `ubuntu-latest` with Ruby 3.4.3.

## Bootstrap / Build / Test / Validate

Follow these steps every time before creating a PR. They are validated against
the repo and CI.

1. Ensure Ruby matches CI when possible

- Prefer Ruby 3.4.3 to reproduce CI. If using a Ruby version manager, run
  `rbenv local 3.4.3` or `asdf local ruby 3.4.3`.

2. Install dependencies (always)

- Run:

  bundle install

- Notes: The repo depends on `sqlite3` for in-memory tests. On macOS you may
  need the SQLite library available (e.g. `brew install sqlite3`) if native gem
  builds fail.

3. Bootstrapping convenience

- This repository includes `bin/setup` and `bin/console` for development
  convenience. Running `bin/setup` installs dependencies and prepares the
  environment.

4. Run the test suite (fast; in-memory SQLite)

- CI runs `bundle exec rake` (default rake task runs specs). Locally run either:

  bundle exec rake
  # or
  bundle exec rspec --format documentation

- Expected result: All specs should pass quickly (this repo's test suite is
  small and uses an in-memory SQLite DB). If tests fail locally but pass in CI,
  check Ruby/bundler versions and native gem compilation (sqlite3).

5. Lint / other checks

- There are no formal linters configured (no RuboCop config present). Keep
  changes minimal and idiomatic Ruby.

## Repository layout (prioritized)

- Root files:
  - activerecord-eager-aggregation.gemspec (gem metadata, required_ruby_version)
  - Gemfile (dev/test dependencies)
  - Rakefile (default task runs RSpec)
  - README.md

- Key directories and files:
  - lib/activerecord/eager/aggregation.rb (core implementation — primary change
    target)
  - lib/activerecord/eager/aggregation/version.rb
  - sig/activerecord/eager/aggregation.rbs (type signatures)
  - spec/spec_helper.rb (in-memory DB setup and model fixtures)
  - spec/activerecord/eager/aggregation_spec.rb
  - .github/workflows/main.yml (CI: runs `bundle exec rake` on Ruby 3.4.3)

## Important implementation notes and conventions

- Tests use an in-memory SQLite DB and define simple models in
  `spec/spec_helper.rb`. Tests are isolated (database cleaned before each
  example) and fast.
- The gem patches ActiveRecord::Relation (modules are included/prepended in
  `lib/.../aggregation.rb`). Small behavioral changes can have wide effect;
  prefer small, well-tested diffs.
- The gemspec excludes spec/ from packaged gem files — tests and dev-only files
  are not packaged.

## Validation checklist for PRs (keep this short & runnable)

Before opening a PR, run locally:

bundle install bundle exec rake

If those succeed, run the same commands in CI or ensure CI matrix (Ruby 3.4.3)
will match.

## Troubleshooting / common pitfalls

- Native `sqlite3` gem failures: ensure system SQLite dev headers are installed
  (macOS: `brew install sqlite3`).
- Ruby mismatch: CI uses 3.4.3; running on older/newer Ruby can change behavior.
  If in doubt, use the CI Ruby version.
- When adding public API surface or changing existing behavior, add/adjust specs
  in `spec/activerecord/eager/aggregation_spec.rb` and run the test suite.

## Agent behavior rules (how a coding agent should operate here)

- Always run the validated commands above (`bundle install` then
  `bundle exec rake`) before proposing a PR.
- Keep changes minimal and focused to one logical change per PR. Run specs and
  only modify implementation files in `lib/` unless tests or docs require
  updates.
- When editing `lib/activerecord/eager/aggregation.rb` prefer adding tests in
  `spec/...` for any behavior change.
- If a test fails locally and you cannot reproduce CI failures, re-run with the
  CI Ruby (`3.4.3`) or report the mismatch to the human reviewer.
- Trust this file first: only perform repo-wide searches if the instructions
  here are incomplete or you see evidence they are wrong.

## Contacts and references

- README.md contains usage and development notes.
- CI workflow: `.github/workflows/main.yml`.

End.
