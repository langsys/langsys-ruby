# frozen_string_literal: true

require "shellwords"

module Langsys
  # Checks CONFORMANCE.md against the canonical format the fleet checker reads, and computes
  # the tally from the rows rather than trusting a hand-written summary.
  module ConformanceChecker
    SPEC_COMMIT_PREFIX = "2dce7f41"
    SPEC_BLOB = "99c86b55de39f7d45cf9c25d931d210953cff8be"

    # The 113 rule ids in that blob, in spec order. Derived, not typed:
    #   git -C ../langsys2 cat-file blob 99c86b55 | grep -oE '^### [A-Z]+-[0-9]+ ' | awk '{print $2}'
    SPEC_IDS = %w[
      GATE-1 GATE-2 GATE-3 GATE-4 GATE-5 GATE-6 GATE-7 GATE-8 GATE-9 GATE-10
      CAT-1 CAT-2 CAT-3 REG-1 REG-2 REG-3 REG-4 REG-5 REG-6 REG-7
      REG-8 REG-9 REG-10 REG-11 REG-12 REG-13 HINT-1 HINT-2 HINT-3 HINT-4
      HINT-5 HINT-6 HINT-7 HINT-8 HINT-9 HINT-10 HINT-11 HINT-12 HINT-13 ICU-1
      ICU-2 ICU-3 ICU-4 ICU-5 ICU-6 CID-1 CID-2 CID-3 CID-4 TOK-1
      TOK-2 TOK-3 TOK-4 TOK-5 TOK-6 MARK-1 MARK-2 MARK-3 MARK-4 SSR-1
      SSR-2 SSR-3 SRV-1 SRV-2 SRV-3 SRV-4 SRV-5 SRV-6 MSG-1 MSG-2
      MSG-3 MSG-4 MSG-5 MSG-6 MSG-7 MSG-8 MSG-9 MSG-10 MSG-11 MSG-12
      MIG-1 MIG-2 MIG-3 MIG-4 MIG-5 MIG-6 MIG-7 MIG-8 MIG-9 SNAP-1
      SNAP-2 SNAP-3 BIND-1 BIND-2 BIND-3 BIND-4 BIND-5 BIND-6 GRANT-1 GRANT-2
      GRANT-3 GRANT-4 CACHE-1 CACHE-2 OBS-1 WIRE-1 WIRE-2 WIRE-3 WIRE-4 WIRE-5
      CONF-1 CONF-2 CONF-3
    ].freeze

    TIERS = ["live", "contract", "mock", "n/a (pure)", "-"].freeze
    IMPLEMENTED_TIERS = ["live", "contract", "n/a (pure)"].freeze
    PLAIN_STATUSES = ["implemented", "provisional", "partial", "not implemented", "held (strip ruling)",
                      "waived"].freeze
    NOT_GREEN = ["provisional", "partial", "not implemented", "waived"].freeze
    TABLE_HEADER = "| Rule | Status | Tier | Evidence |"
    PROFILES_ROW = "| **Profiles** | all, server |"

    Row = Struct.new(:id, :status, :tier, :evidence, :line, keyword_init: true)
    Result = Struct.new(:errors, :rows, keyword_init: true) do
      def ok? = errors.empty?
    end

    module_function

    # Check a file, re-derive the header blob from a local langsys2 checkout when one is
    # present, and print the report. Returns the Result.
    def run(path, spec_repo: nil, quiet: false)
      text = File.read(path)
      result = check(text)
      result.errors.concat(rederivation_errors(text, spec_repo)) if spec_repo
      puts report(result) unless quiet
      result
    end

    def check(text)
      errors = header_errors(text)
      rows, table_errors = parse_table(text)
      errors.concat(table_errors)
      errors.concat(id_errors(rows))
      rows.each { |row| errors.concat(row_errors(row)) }
      Result.new(errors: errors, rows: rows)
    end

    def header_errors(text)
      errors = []
      revision = text.lines.find { |l| l.start_with?("| **Spec revision read** |") }
      return ["header: no `| **Spec revision read** |` row"] + profiles_errors(text) if revision.nil?

      blob = revision[/blob ([0-9a-f]{40})/, 1]
      commit = revision[/langsys2 ([0-9a-f]{7,40})/, 1]
      errors << "header: no 40-hex id after `blob`" if blob.nil?
      errors << "header: cites blob #{blob}, target is #{SPEC_BLOB}" if blob && blob != SPEC_BLOB
      errors << "header: no langsys2 commit before the blob" if commit.nil?
      if commit && !commit.start_with?(SPEC_COMMIT_PREFIX)
        errors << "header: cites commit #{commit}, target is #{SPEC_COMMIT_PREFIX}..."
      end
      errors + profiles_errors(text)
    end

    def profiles_errors(text)
      return [] if text.lines.any? { |l| l.chomp == PROFILES_ROW }

      ["header: Profiles row must be exactly `#{PROFILES_ROW}`"]
    end

    def parse_table(text)
      lines = text.lines.map(&:chomp)
      starts = lines.each_index.select { |i| lines[i].start_with?(TABLE_HEADER) }
      unless starts.size == 1
        return [[], ["status table: expected exactly one `#{TABLE_HEADER}` header, found #{starts.size}"]]
      end

      rows = []
      errors = []
      ((starts.first + 2)...lines.size).each do |i|
        break unless lines[i].start_with?("|")

        row, error = parse_row(lines[i], i + 1)
        row ? rows << row : errors << error
      end
      [rows, errors]
    end

    def parse_row(line, number)
      cells = line.delete_prefix("|").delete_suffix("|").split("|").map(&:strip)
      if cells.size < 4
        return [nil,
                "line #{number}: expected at least 4 cells, found #{cells.size} (a raw `|` inside a cell splits it)"]
      end

      [Row.new(id: cells[0], status: cells[1].delete("*"), tier: cells[2], evidence: cells[3..].join(" | "),
               line: number), nil]
    end

    def id_errors(rows)
      ids = rows.map(&:id)
      errors = rows.reject { |r| r.id.match?(/\A[A-Z]+-[0-9]+\z/) }
                   .map { |r| "line #{r.line}: `#{r.id}` is not exactly one rule id" }
      ids.tally.select { |_, n| n > 1 }.each_key { |id| errors << "rule #{id} appears more than once" }
      (SPEC_IDS - ids).each { |id| errors << "rule #{id} is missing" }
      (ids.grep(/\A[A-Z]+-[0-9]+\z/) - SPEC_IDS).each { |id| errors << "rule #{id} is not in blob #{SPEC_BLOB[0, 8]}" }
      errors
    end

    def row_errors(row)
      at = "line #{row.line} #{row.id}"
      errors = []
      errors << "#{at}: unknown status `#{row.status}`" unless valid_status?(row.status)
      errors << "#{at}: unknown tier `#{row.tier}`" unless TIERS.include?(row.tier)
      if row.status == "implemented" && !IMPLEMENTED_TIERS.include?(row.tier)
        errors << "#{at}: implemented needs live, contract or n/a (pure), got `#{row.tier}`"
      end
      errors << "#{at}: provisional needs mock, got `#{row.tier}`" if row.status == "provisional" && row.tier != "mock"
      if %w[implemented provisional].include?(row.status) && row.evidence.strip.empty?
        errors << "#{at}: #{row.status} needs named evidence"
      end
      if row.status == "waived" && !row.evidence.match?(/agree/i)
        errors << "#{at}: waived needs the operator's recorded agreement"
      end
      errors
    end

    def valid_status?(status)
      PLAIN_STATUSES.include?(status) ||
        status.match?(%r{\An/a \(profile: (browser|binding)(, (browser|binding))?\)\z}) ||
        status.match?(%r{\An/a \(architecture: .{12,}\)\z})
    end

    def group_key(row)
      if row.status == "implemented" && row.tier == "n/a (pure)"
        if row.evidence.match?(/cross-implementation fixture/i)
          return "implemented, n/a (pure), cross-implementation fixture"
        end

        return "implemented, n/a (pure), in-process"
      end
      return "implemented, #{row.tier}" if row.status == "implemented"
      return "n/a (profile)" if row.status.start_with?("n/a (profile:")
      return "n/a (architecture)" if row.status.start_with?("n/a (architecture:")

      row.status
    end

    def groups(rows) = rows.each_with_object(Hash.new(0)) { |r, h| h[group_key(r)] += 1 }

    def green_blockers(rows) = rows.select { |r| NOT_GREEN.include?(r.status) }

    def rederivation_errors(text, spec_repo)
      commit = text[/langsys2 ([0-9a-f]{7,40})/, 1]
      unless commit && File.directory?(spec_repo)
        puts "conformance: no langsys2 checkout at #{spec_repo}, header blob not re-derived"
        return []
      end

      listing = `git -C #{Shellwords.escape(spec_repo)} ls-tree #{commit} docs/sdk-spec.mdx 2>/dev/null`
      derived = listing[/blob ([0-9a-f]{40})/, 1]
      return [] if derived == SPEC_BLOB

      ["header: langsys2 #{commit} re-derives blob #{derived.inspect}, not #{SPEC_BLOB}"]
    end

    def report(result)
      out = ["conformance: #{result.rows.size} rows, #{result.errors.size} format error(s)"]
      result.errors.first(40).each { |e| out << "  ERROR #{e}" }
      groups(result.rows).sort_by { |k, _| k }.each { |k, n| out << format("  %<key>-58s %<n>d", key: k, n: n) }
      out.join("\n")
    end
  end
end
