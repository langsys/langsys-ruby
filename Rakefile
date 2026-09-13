# frozen_string_literal: true

require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec) do |t|
  # Skip the live-nova integration specs by default; run them with `rake integration`.
  t.rspec_opts = "--tag ~integration"
end

RSpec::Core::RakeTask.new(:integration) do |t|
  t.rspec_opts = "--tag integration"
end

begin
  require "rubocop/rake_task"
  RuboCop::RakeTask.new
rescue LoadError
  # rubocop not installed — skip the lint task
end

desc "Validate the RBS type signatures in sig/"
task :rbs do
  sh "rbs -I sig validate"
end

task default: %i[spec]

namespace :conformance do
  require_relative "spec/support/conformance_checker"
  conformance_file = ENV.fetch("CONFORMANCE_FILE", "CONFORMANCE.md")

  desc "Check CONFORMANCE.md against the canonical format; fails on any format error"
  task :check do
    spec_repo = File.expand_path("../langsys2", __dir__)
    result = Langsys::ConformanceChecker.run(conformance_file, spec_repo: spec_repo)
    abort "conformance: format check FAILED" unless result.ok?
  end

  desc "Fail unless every row is green (no provisional, partial, not implemented or waived)"
  task green: :check do
    result = Langsys::ConformanceChecker.run(conformance_file, quiet: true)
    blockers = Langsys::ConformanceChecker.green_blockers(result.rows)
    blockers.each { |r| puts "  NOT GREEN #{r.id}: #{r.status}" }
    abort "conformance: #{blockers.size} row(s) not green" unless blockers.empty?

    puts "conformance: GREEN"
  end
end
