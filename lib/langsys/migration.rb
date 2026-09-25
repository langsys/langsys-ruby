# frozen_string_literal: true

require "json"
require "yaml"
require_relative "errors"

module Langsys
  # Legacy-key migration (spec MIG family). An app keeps its keys and its source-language file;
  # in this mode t(arg) resolves arg as a key first. A hit registers the key's source value,
  # converted to Langsys/ICU syntax, under the key's namespace; a miss treats arg as literal
  # source text. The key itself never reaches Langsys, so a later codemod can inline the value
  # and delete the file without moving an id.
  #
  # Ruby reads the formats its ecosystem writes: rails-i18n (config/locales/*.yml), gettext
  # (.po) and plain JSON. Any other configured format is refused at load, by name.
  class Migration
    SUPPORTED = %w[rails-i18n gettext plain].freeze
    PLURAL_KEYS = %w[zero one two few many other 0 1].freeze
    CATEGORY_ORDER = %w[zero one two few many other].freeze

    Hit = Struct.new(:phrase, :category, :file, :key, keyword_init: true)
    Result = Struct.new(:phrase, :warning, keyword_init: true)

    attr_reader :duplicates, :problems

    # +files+: paths, or {path:, format:} hashes. +source_locale+ picks a rails-i18n root.
    def initialize(files, source_locale: "en", logger: nil)
      @specs = Array(files).map { |f| normalize_spec(f) }
      @source_locale = source_locale.to_s
      @logger = logger
      @entries = nil
      @duplicates = []
      @problems = []
    end

    # Whether +arg+ is a key in the files. Quiet: a bridge asks this for every lookup its host
    # makes, most of which are never registered, so a miss here is not MIG-6 drift.
    def key?(arg)
      load! if @entries.nil?
      @entries.key?(arg)
    end

    # MIG-2: a Hit for a key in the files, or nil for a literal (MIG-6: logged at debug).
    def lookup(arg)
      load! if @entries.nil?
      hit = @entries[arg]
      unless hit
        @logger&.debug("langsys: #{arg.inspect} is not a key in the migration source files; " \
                       "registering it as literal text")
      end
      hit
    end

    # -- conversion (MIG-4), public for a binding's bridge ----------------------

    PLACEHOLDERS = [
      [/\{\{\s*([A-Za-z_]\w*)\s*\}\}/, '{\1}'], # vue-i18n / i18next
      [/%\{([A-Za-z_]\w*)\}/, '{\1}'],          # Rails
      [/%\(([A-Za-z_]\w*)\)[sd]/, '{\1}'],      # Python
      [/(?<![\w:]):([a-z][a-z0-9_]*)/, '{\1}']  # Laravel
    ].freeze
    # Forms a {name} cannot express: formatting directives, positional %s, and Laravel's
    # case-changing :Name / :NAME.
    UNCONVERTIBLE = Regexp.union(
      /%<[A-Za-z_]\w*>[-+ #0-9.]*[a-zA-Z]/, # Rails %<name>.2f
      /%\([A-Za-z_]\w*\)(?![sd])[-+ #0-9.]*[a-zA-Z]/, # Python %(name).2f
      /%[sd]/,                                       # positional
      /(?<![\w:]):[A-Z]\w*/                          # Laravel :Name / :NAME
    )

    # A file value converted to a phrase. Unconvertible forms, and a pipe the format does not
    # read as a plural, register verbatim with a warning.
    def self.convert(value, format: "plain")
      text = value.to_s
      bare = text.gsub("%%", "")
      if (form = bare[UNCONVERTIBLE])
        return Result.new(phrase: text, warning: "registered verbatim: #{form} cannot be written as a {name}")
      end
      if text.include?("|")
        return Result.new(phrase: text,
                          warning: "registered verbatim: a | in a #{format} file is not a plural")
      end

      Result.new(phrase: placeholders(text))
    end

    def self.placeholders(text)
      out = PLACEHOLDERS.reduce(text) { |acc, (pattern, replacement)| acc.gsub(pattern, replacement) }
      out.gsub("%%", "%")
    end

    # MIG-2: a literal miss converted under the syntax of the entry point that received it.
    # Langsys t() converts nothing; Rails I18n.t converts only the %{key} placeholders it was
    # passed and leaves any other %{word} as written.
    def self.convert_literal(text, entry_point:, params: nil)
      case entry_point.to_sym
      when :langsys then text
      when :rails
        keys = (params || {}).keys.map(&:to_s)
        text.gsub(/%\{([A-Za-z_]\w*)\}/) do
          keys.include?(Regexp.last_match(1)) ? "{#{Regexp.last_match(1)}}" : Regexp.last_match(0)
        end
      else raise ArgumentError, "langsys: unknown migration entry point #{entry_point.inspect}"
      end
    end

    # rails-i18n: zero and 0 are =0, 1 is =1 (the i18n gem picks them only at that count);
    # one..other are CLDR categories. Branches spelled canonically, the count rendered as #.
    def self.rails_plural(hash)
      branches = {}
      hash.each do |key, value|
        name = { "zero" => "=0", "0" => "=0", "1" => "=1" }.fetch(key.to_s, key.to_s)
        branches[name] ||= value.to_s
      end
      icu_plural(branches)
    end

    # gettext: untranslated gettext returns msgid only when n is exactly 1.
    def self.gettext_plural(singular, plural)
      icu_plural({ "=1" => singular, "other" => plural })
    end

    def self.icu_plural(branches)
      exact = branches.keys.grep(/\A=\d+\z/).sort_by { |k| k[1..].to_i }
      order = exact + CATEGORY_ORDER.select { |k| branches.key?(k) }
      body = order.map { |k| "#{k} {#{placeholders(branches[k].to_s).gsub('{count}', '#')}}" }.join(" ")
      "{count, plural, #{body}}"
    end

    private

    def normalize_spec(file)
      path, format = file.is_a?(Hash) ? [file[:path] || file["path"], file[:format] || file["format"]] : [file, nil]
      path = path.to_s
      format = (format || default_format(path)).to_s
      if path.end_with?(".mo")
        raise ConfigurationError, "langsys: #{path} is a compiled .mo; point the migration at the .po it was " \
                                  "compiled from (#{path.sub(/\.mo\z/, '.po')})"
      end
      unless SUPPORTED.include?(format)
        raise ConfigurationError, "langsys: migration format #{format.inspect} (#{path}) is not one Ruby reads; " \
                                  "supported: #{SUPPORTED.join(', ')}"
      end

      { path: path, format: format }
    end

    def default_format(path)
      case File.extname(path).downcase
      when ".yml", ".yaml" then "rails-i18n"
      when ".po" then "gettext"
      when ".php" then "laravel"
      else "plain"
      end
    end

    def load!
      @entries = {}
      @specs.each do |spec|
        each_entry(spec) do |key, hit|
          if @entries.key?(key)
            @duplicates << key unless @duplicates.include?(key)
          else
            @entries[key] = hit
          end
        end
      end
    end

    def each_entry(spec, &block)
      case spec[:format]
      when "rails-i18n" then rails_entries(spec, &block)
      when "gettext" then gettext_entries(spec, &block)
      else plain_entries(spec, &block)
      end
    end

    def plain_entries(spec, &block)
      flatten(JSON.parse(File.read(spec[:path])), []) { |key, value| yield_value(spec, key, value, &block) }
    end

    def rails_entries(spec, &block)
      doc = YAML.safe_load_file(spec[:path]) || {}
      root = doc.keys.find { |k| k.to_s.casecmp?(@source_locale) } ||
             doc.keys.find { |k| k.to_s.split(/[-_]/).first.casecmp?(@source_locale.split(/[-_]/).first) }
      return if root.nil?

      flatten(doc[root], [], plural: true) do |key, value|
        if value.is_a?(Hash)
          block.call(key,
                     Hit.new(phrase: self.class.rails_plural(value), category: namespace(key), file: spec[:path],
                             key: key))
        else
          yield_value(spec, key, value, &block)
        end
      end
    end

    def gettext_entries(spec)
      PoFile.parse(File.read(spec[:path])).each do |entry|
        next if entry[:msgid].empty?

        phrase = if entry[:msgid_plural]
                   self.class.gettext_plural(entry[:msgid],
                                             entry[:msgid_plural])
                 else
                   self.class.convert(
                     entry[:msgid], format: "gettext"
                   ).phrase
                 end
        yield entry[:msgid], Hit.new(phrase: phrase, category: entry[:msgctxt], file: spec[:path], key: entry[:msgid])
      end
    end

    def yield_value(spec, key, value)
      return unless value.is_a?(String)

      result = self.class.convert(value, format: spec[:format])
      if result.warning
        @logger&.warn("langsys: #{spec[:path]} key #{key}: #{result.warning}")
        @problems << { file: spec[:path], key: key, issue: result.warning }
      end
      yield key, Hit.new(phrase: result.phrase, category: namespace(key), file: spec[:path], key: key)
    end

    # Nested keys resolve by path; a rails-i18n plural hash is one leaf.
    def flatten(node, path, plural: false, &block)
      if node.is_a?(Hash) && !(plural && plural_hash?(node))
        node.each { |k, v| flatten(v, path + [k.to_s], plural: plural, &block) }
      elsif !path.empty?
        block.call(path.join("."), node)
      end
    end

    def plural_hash?(node)
      !node.empty? && node.keys.all? { |k| PLURAL_KEYS.include?(k.to_s) } && node.values.all?(String)
    end

    def namespace(key)
      parts = key.split(".")
      parts.length > 1 ? parts.first : nil
    end

    # A minimal .po reader: msgctxt, msgid, msgid_plural, with continuation lines.
    module PoFile
      module_function

      def parse(text)
        entries = []
        current = {}
        field = nil
        text.each_line do |line|
          line = line.strip
          if line.empty?
            entries << current unless current.empty?
            current = {}
            field = nil
          elsif (m = line.match(/\A(msgctxt|msgid_plural|msgid|msgstr(?:\[\d+\])?)\s+"(.*)"\z/))
            field = m[1].to_sym
            current[field] = unescape(m[2])
          elsif (m = line.match(/\A"(.*)"\z/)) && field
            current[field] += unescape(m[1])
          end
        end
        entries << current unless current.empty?
        entries.select { |e| e.key?(:msgid) }
      end

      def unescape(text)
        text.gsub(/\\(.)/) do
          { "n" => "\n", "t" => "\t", '"' => '"', "\\" => "\\" }.fetch(Regexp.last_match(1), Regexp.last_match(1))
        end
      end
    end
  end
end
