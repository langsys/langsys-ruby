# frozen_string_literal: true

require_relative "lib/langsys/version"

Gem::Specification.new do |spec|
  spec.name = "langsys"
  spec.version = Langsys::VERSION
  spec.authors = ["Langsys"]
  spec.email = ["support@langsys.dev"]

  spec.summary = "Ruby SDK for the Langsys Translation Manager — realtime, continuous translations."
  spec.description = <<~DESC
    The framework-agnostic Ruby base SDK for Langsys. Fetches and caches translation
    catalogs, resolves phrases (the phrase is both the lookup key and the base-language
    default), interpolates parameters with locale-aware CLDR formatting and an ICU
    MessageFormat subset, discovers and registers new phrases, and exposes reference data
    (countries, currencies, locales). Framework wrappers (Rails, …) build thinly on top.
  DESC
  spec.homepage = "https://github.com/langsys/langsys-ruby"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*.rb", "sig/**/*.rbs", "README.md", "LICENSE", "CHANGELOG.md"]
  spec.require_paths = ["lib"]

  # CLDR plural rules + locale-aware number/date formatting (pure Ruby, no native extension).
  spec.add_dependency "twitter_cldr", "~> 6.0"
end
