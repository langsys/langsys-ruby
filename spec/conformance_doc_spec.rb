# frozen_string_literal: true

require "spec_helper"

# CONFORMANCE.md's summary is a claim about its own rules table. Wave 2 shipped a summary
# that reconciled with nothing in that table — miscounted, graded rules as implemented that
# the table marked otherwise, and had no bucket for two of its statuses. A hand-maintained
# tally of 60-odd rows drifts on the first edit and nothing notices, so it is computed here
# and asserted: the document fails the build rather than the reader.
#
# Namespaced in a module rather than left as bare constants in the describe block. A
# constant assigned inside a block binds on Object and will silently rebind a same-named
# one in another spec file — an earlier draft of this file did exactly that to the CID
# suite's fixture rows and broke three of its integrity assertions.
module ConformanceDoc
  PATH = File.expand_path("../CONFORMANCE.md", __dir__)
  TEXT = File.read(PATH)
  ALLOWED = ["implemented", "provisional", "provisional (no test)", "partial",
             "not implemented", "n/a (architecture)", "waived"].freeze

  module_function

  # A rules-table row: "| GATE-1 | implemented | live | … |". The id cell may hold a range
  # ("BIND-1..6") or a list ("HINT-1, 3–12"), so it is expanded before counting.
  def rows
    TEXT.each_line.filter_map do |line|
      next unless line =~ /^\| ([A-Z]+-[0-9][^|]*) \| ([^|]+) \|/

      [Regexp.last_match(1).strip, Regexp.last_match(2).strip.delete("*")]
    end
  end

  def expand(ids)
    prefix = ids[/\A([A-Z]+)-/, 1]
    ids.split(",").flat_map do |part|
      case part.strip
      when /\A([A-Z]+)-(\d+)\.\.(\d+)\z/
        (Regexp.last_match(2).to_i..Regexp.last_match(3).to_i).map { |n| "#{Regexp.last_match(1)}-#{n}" }
      when /\A(\d+)[\u2013-](\d+)\z/
        (Regexp.last_match(1).to_i..Regexp.last_match(2).to_i).map { |n| "#{prefix}-#{n}" }
      else
        [part.strip]
      end
    end
  end

  def graded
    rows.flat_map { |ids, status| expand(ids).map { |id| [id, status] } }
  end

  def tally
    graded.each_with_object(Hash.new(0)) { |(_, status), h| h[status] += 1 }
  end

  def bucket(status)
    return "n/a — profile" if status.start_with?("n/a (profile:")
    return "n/a — architecture" if status == "n/a (architecture)"

    status
  end
end

RSpec.describe "CONFORMANCE.md" do
  let(:graded) { ConformanceDoc.graded }
  let(:tally) { ConformanceDoc.tally }
  let(:text) { ConformanceDoc::TEXT }

  it "grades every rule in the spec exactly once" do
    ids = graded.map(&:first)
    expect(ids.size).to eq(67), "expected all 67 spec rules graded, found #{ids.size}"
    expect(ids.tally.select { |_, n| n > 1 }).to be_empty
  end

  it "uses only the documented status vocabulary" do
    unknown = tally.keys.reject { |s| ConformanceDoc::ALLOWED.include?(s) || s.start_with?("n/a (profile:") }
    expect(unknown).to be_empty, "unrecognised status(es): #{unknown.inspect}"
  end

  it "has a summary whose counts match the rules table" do
    summary = text[/^## Summary\n(.*?)^## /m, 1].to_s
    claimed = summary.each_line.filter_map do |line|
      next unless line =~ /^\| ([^|]+) \| \*{0,2}(\d+)\*{0,2} \|/

      [Regexp.last_match(1).strip.delete("*"), Regexp.last_match(2).to_i]
    end.to_h
    claimed.delete("total")

    actual = tally.each_with_object(Hash.new(0)) { |(status, n), h| h[ConformanceDoc.bucket(status)] += n }
    expect(claimed).to eq(actual)
  end

  it "reports a total equal to the number of graded rules" do
    expect(text[/^\| \*\*total\*\* \| \*\*(\d+)\*\*/, 1].to_i).to eq(graded.size)
  end

  it "keeps the two kinds of n/a distinct" do
    # A profile row goes stale only if a Profiles line moves; an architecture row can rot
    # under you with no rule changing. One label would hide the one that rots silently.
    expect(tally.keys).to include("n/a (architecture)")
    expect(tally.keys.any? { |k| k.start_with?("n/a (profile:") }).to be(true)
  end
end
