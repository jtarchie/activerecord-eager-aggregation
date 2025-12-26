# frozen_string_literal: true

require_relative 'lib/activerecord/eager/aggregation/version'

Gem::Specification.new do |spec|
  spec.name = 'activerecord-eager-aggregation'
  spec.version = Activerecord::Eager::Aggregation::VERSION
  spec.authors = ['JT Archie']
  spec.email = ['jtarchie@gmail.com']

  spec.summary = 'Eager loading for ActiveRecord aggregations to avoid N+1 queries'
  spec.description = 'This gem provides eager aggregation support for ActiveRecord relations, ' \
                     'optimizing N+1 queries for aggregations (COUNT, SUM, AVG, MAX, MIN) ' \
                     'by using GROUP BY to batch fetch results for multiple records at once.'
  spec.homepage = 'https://github.com/jtarchie/activerecord-eager-aggregation'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.1.0'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = 'https://github.com/jtarchie/activerecord-eager-aggregation'
  spec.metadata['changelog_uri'] = 'https://github.com/jtarchie/activerecord-eager-aggregation/blob/main/CHANGELOG.md'
  spec.metadata['rubygems_mfa_required'] = 'true'

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ .git .github appveyor Gemfile])
    end
  end
  spec.bindir = 'exe'
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ['lib']

  # Uncomment to register a new dependency of your gem
  spec.add_dependency 'activerecord', '>= 6.0'

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
end
