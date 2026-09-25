# frozen_string_literal: true

module Langsys
  # Server messages (spec MSG family). A server registers the templates of its validation errors
  # and system messages ahead of time, because no visitor's SDK ever sees them rendered.
  #
  # An entry is { field?, code, message, template, params? }. The template is a whole sentence in
  # the source language with everything translatable written in; {name} markers carry only values
  # that are not translatable (a number, a date, raw input), and message is the template filled.
  # The envelope around the entries is the app's; this module ships the langsys default and reads
  # entries wherever a body carries them.
  module Messages
    MARKER = /\{([a-z][a-z0-9_]*)\}/
    CODE = /\A[a-z][a-z0-9]*(?:_[a-z0-9]+)*\z/

    # MSG-2: the shared vocabulary. A code is branched on, never used to choose text, and
    # retired rather than renamed.
    CODES = %w[required invalid_type invalid_format invalid_option invalid_date not_found already_taken mismatch
               too_short too_long too_small too_large too_few too_many not_allowed already_member not_member
               already_owner expired not_available invalid].freeze

    SIZE_CODES = {
      string: %w[too_short too_long], number: %w[too_small too_large], list: %w[too_few too_many]
    }.freeze

    DEFAULT_CATEGORY = "Errors"

    module_function

    # The marker names in first-appearance order, each once.
    def markers(template)
      template.to_s.scan(MARKER).flatten.uniq
    end

    # MSG-4: each marker with a scalar param is filled; a missing, null or structured param
    # stays its literal marker rather than being blanked.
    def fill(template, params)
      params ||= {}
      template.to_s.gsub(MARKER) do
        name = Regexp.last_match(1)
        value = params.key?(name) ? params[name] : params[name.to_sym]
        scalar?(value) ? value.to_s : Regexp.last_match(0)
      end
    end

    def scalar?(value)
      value.is_a?(String) || value.is_a?(Numeric) || value == true || value == false
    end

    # A well-formed entry. params is kept only for the template's own markers, and omitted
    # when it has none; numbers stay numbers.
    def entry(code:, template:, params: nil, field: nil)
      unless code.to_s.match?(CODE)
        raise ArgumentError,
              "langsys: message code #{code.inspect} is not a snake_case slug"
      end

      names = markers(template)
      kept = (params || {}).each_with_object({}) do |(key, value), out|
        out[key.to_s] = value if names.include?(key.to_s)
      end
      result = {}
      result["field"] = field.to_s unless field.nil? || field.to_s.empty?
      result.merge!("code" => code.to_s, "message" => fill(template, kept), "template" => template.to_s)
      result["params"] = kept unless names.empty?
      result
    end

    # A failure that arrives as text only (MSG-9's pieces for a binding's normalizer).
    def from_text(text)
      { "code" => "invalid", "message" => text.to_s, "template" => text.to_s }
    end

    # MSG-2: size codes by the field's type and the bound that failed.
    def size_code(type, bound)
      pair = SIZE_CODES.fetch(type.to_sym)
      bound.to_sym == :lower ? pair[0] : pair[1]
    end

    # MSG-1: the langsys default envelope.
    def envelope(entries, message: "The request failed validation.", code: "validation_failed")
      { "status" => false,
        "error" => { "code" => code, "message" => message, "template" => message, "errors" => entries } }
    end

    # MSG-1: every entry in +body+, in document order, wherever it sits. +key+ narrows the
    # search to a dotted path; +resolver+ maps an app's native failures to entries instead.
    # An entry's own params are never searched.
    def resolve(body, key: nil, resolver: nil)
      return Array(resolver.call(body)).filter_map { |candidate| normalize(candidate) } if resolver

      node = key.nil? ? body : dig(body, key)
      node.nil? ? [] : collect(node, [])
    end

    def dig(body, key)
      key.to_s.split(".").reduce(body) do |node, part|
        case node
        when Hash then node.key?(part) ? node[part] : (return nil)
        when Array then part.match?(/\A\d+\z/) ? node[part.to_i] : (return nil)
        else return nil
        end
      end
    end

    def collect(node, out)
      case node
      when Array then node.each { |child| collect(child, out) }
      when Hash
        found = normalize(node)
        out << found if found
        node.each { |name, child| collect(child, out) unless found && name.to_s == "params" }
      end
      out
    end

    def normalize(candidate)
      return nil unless candidate.is_a?(Hash)

      pieces = %w[code message template].to_h { |k| [k, candidate[k] || candidate[k.to_sym]] }
      return nil unless pieces.values.all?(String)

      field = candidate["field"] || candidate[:field]
      params = candidate.key?("params") ? candidate["params"] : candidate[:params]
      result = {}
      result["field"] = field if field.is_a?(String) && !field.empty?
      result.merge!(pieces)
      result["params"] = params unless params.nil?
      result
    end

    # MSG-7/MSG-11: the template list a server can emit, checked as each template is added.
    class TemplateCatalog
      LABEL_MARKERS = %w[attribute field label other values].freeze
      FRAMEWORK_PLACEHOLDER = /(?<![\w:]):[a-z][a-z_]*/
      BRACE = /\{[^{}]*\}/

      attr_reader :templates, :problems

      def initialize
        @templates = []
        @problems = []
      end

      def add(template, source: nil, field: nil)
        issue = issue_for(template.to_s)
        if issue
          @problems << { source: source, field: field, issue: issue[0], fix: issue[1] }
        elsif !@templates.include?(template)
          @templates << template
        end
        self
      end

      # A problem that is not a bad template: a validated field with no label (MSG-10), or a
      # custom rule whose templates the app has not declared. The command names it and exits 1.
      def problem(source:, issue:, fix:, field: nil)
        @problems << { source: source, field: field, issue: issue, fix: fix }
        self
      end

      def issue_for(template)
        if template.include?("{{") || template.match?(FRAMEWORK_PLACEHOLDER)
          placeholder = template[/\{\{[^}]*\}\}/] || template[FRAMEWORK_PLACEHOLDER]
          return ["framework placeholder #{placeholder} left in the template",
                  "write the value into the sentence, or use a {name} marker for a non-translatable value"]
        end
        label = Messages.markers(template).find { |name| LABEL_MARKERS.include?(name) }
        if label
          return ["marker {#{label}} carries a label", "write the label into the sentence: one template per label"]
        end

        odd = template.scan(BRACE).find { |brace| !brace.match?(/\A#{MARKER.source}\z/o) }
        return ["#{odd} is not a {name} marker", "markers are {lower_snake_case} only"] if odd

        nil
      end
    end

    # A named set of templates a server can emit; the block adds them to a catalog.
    class Source
      attr_reader :name

      def initialize(name, &block)
        @name = name
        @block = block
      end

      def collect(catalog)
        recorder = Object.new
        source = @name
        recorder.define_singleton_method(:add) do |template, field: nil|
          catalog.add(template, source: source, field: field)
        end
        recorder.define_singleton_method(:problem) do |issue:, fix:, field: nil|
          catalog.problem(source: source, field: field, issue: issue, fix: fix)
        end
        @block.call(recorder)
        catalog
      end
    end

    def sources
      @sources ||= []
    end

    # MSG-7: list every template the sources declare, register them with +register+, and exit
    # non-zero naming each one that cannot be listed.
    module Command
      module_function

      def run(sources:, client: nil, register: false, out: $stdout)
        catalog = TemplateCatalog.new
        sources.each { |source| source.collect(catalog) }
        catalog.templates.each { |template| out.puts "✓ #{template}" }
        catalog.problems.each do |p|
          out.puts "✗ #{[p[:source], p[:field]].compact.join('.')}: #{p[:issue]} — #{p[:fix]}"
        end
        register_new(client, catalog.templates, out) if register && client
        catalog.problems.empty? ? 0 : 1
      end

      def register_new(client, templates, out)
        fresh = templates.reject { |template| client.message_template_known?(template) }
        client.register_phrases(fresh.map { |t| { phrase: t, category: client.messages_category } }) unless fresh.empty?
        out.puts "registered #{fresh.size} new template(s) under #{client.messages_category}"
      end
    end
  end
end
