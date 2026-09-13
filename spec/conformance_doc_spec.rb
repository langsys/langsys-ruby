# frozen_string_literal: true

require "spec_helper"
require_relative "support/conformance_checker"

# CONFORMANCE.md is checked by the same code `rake conformance:check` runs, so the build and
# the rake task cannot disagree about what the file says, and the tally is computed from the
# table rather than typed beside it. The previous version of this file parsed its own
# older table shape and would have kept passing against a document the fleet checker
# rejects.
module ConformanceDoc
  PATH = File.expand_path("../CONFORMANCE.md", __dir__)
  SPEC_REPO = File.expand_path("../../langsys2", __dir__)
  # Meta-rules discharged by the document and this checker rather than by runtime code.
  META_RULES = %w[CONF-2 CONF-3].freeze
  CLAIMS = %w[implemented provisional partial].freeze
end

RSpec.describe "CONFORMANCE.md" do
  let(:result) do
    Langsys::ConformanceChecker.run(ConformanceDoc::PATH, spec_repo: ConformanceDoc::SPEC_REPO, quiet: true)
  end

  it "passes the canonical-format check: header, profiles, all 79 ids exactly once, status and tier" do
    expect(result.errors).to be_empty, result.errors.first(20).join("\n")
  end

  it "names a re-appliable mutation on every row that claims runtime behaviour (CONF-3)" do
    claims = result.rows.select { |r| ConformanceDoc::CLAIMS.include?(r.status) }
    unproven = claims.reject { |r| ConformanceDoc::META_RULES.include?(r.id) || r.evidence.include?(" red (") }
    expect(unproven.map(&:id)).to be_empty
  end

  it "gives every n/a row its reason" do
    bare = result.rows.select { |r| r.status.start_with?("n/a") && r.evidence.strip.length < 12 }
    expect(bare.map(&:id)).to be_empty
  end

  it "fails the check when a row carries two ids (positive control)" do
    broken = File.read(ConformanceDoc::PATH).sub(/^\| GATE-2 \|/, "| GATE-1 |")
    errors = Langsys::ConformanceChecker.check(broken).errors
    expect(errors).to include(a_string_matching(/GATE-1 appears more than once/))
      .and include(a_string_matching(/GATE-2 is missing/))
  end
end
