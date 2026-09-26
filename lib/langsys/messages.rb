# frozen_string_literal: true

module Langsys
  # Server messages (spec MSG family). A server registers the templates of its validation errors
  # and system messages ahead of time, because no visitor's SDK ever sees them rendered.
  #
  # What translation needs is the framework's own sentence, unfilled (the template), and the
  # params that fill its {name} markers; message is the filled template, the fallback a client
  # shows. Everything around that pair is the framework's and passes through unchanged: its code
  # for the failure, its field path, and the error body the entries are attached to.
  module Messages
    MARKER = /\{([a-z][a-z0-9_]*)\}/
    PIECES = %w[template params message field code].freeze
    DEFAULT_CATEGORY = "Errors"
    DEFAULT_KEY = "messages"

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

    # An entry: the template and the params for its own markers (omitted when it has none,
    # numbers kept as numbers), message filled from them, and the framework's field and code
    # passed through unchanged when it has them (MSG-1, MSG-2).
    def entry(template:, params: nil, field: nil, code: nil)
      names = markers(template)
      kept = (params || {}).each_with_object({}) do |(key, value), out|
        out[key.to_s] = value if names.include?(key.to_s)
      end
      result = { "template" => template.to_s }
      result["params"] = kept unless names.empty?
      result["message"] = fill(template, kept)
      result["field"] = field.to_s unless field.nil? || field.to_s.empty?
      result["code"] = code unless code.nil?
      result
    end

    # MSG-9: a failure that arrives as finished text registers as that text, with no params.
    def from_text(text)
      { "template" => text.to_s, "message" => text.to_s }
    end

    # MSG-1: the framework's native error body, unchanged, with the entries attached under +key+.
    def attach(body, entries, key: DEFAULT_KEY)
      body.merge(key.to_s => entries)
    end

    # MSG-1: every entry in +body+, in document order. +key+ narrows the search to a dotted path,
    # +names+ maps renamed pieces, and +resolver+ maps an app's native failures to entries instead.
    # An entry's own params are never searched.
    def resolve(body, key: nil, resolver: nil, names: {})
      return Array(resolver.call(body)).filter_map { |candidate| normalize(candidate, names) } if resolver

      node = key.nil? ? body : dig(body, key)
      node.nil? ? [] : collect(node, names, [])
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

    def collect(node, names, out)
      case node
      when Array then node.each { |child| collect(child, names, out) }
      when Hash
        found = normalize(node, names)
        out << found if found
        params_key = names.fetch("params", "params")
        node.each { |name, child| collect(child, names, out) unless found && name.to_s == params_key }
      end
      out
    end

    # An entry is an object with a string template beside a message or params; anything else is
    # not looked up (a client shows its message).
    def normalize(candidate, names = {})
      return nil unless candidate.is_a?(Hash)

      read = ->(piece) { candidate[names.fetch(piece, piece)] || candidate[names.fetch(piece, piece).to_sym] }
      template = read.call("template")
      message = read.call("message")
      params = read.call("params")
      return nil unless template.is_a?(String) && (message.is_a?(String) || params.is_a?(Hash))

      result = { "template" => template }
      result["params"] = params unless params.nil?
      result["message"] = message.is_a?(String) ? message : fill(template, params)
      field = read.call("field")
      result["field"] = field if field.is_a?(String) && !field.empty?
      code = read.call("code")
      result["code"] = code unless code.nil?
      result
    end

    # MSG-7/MSG-11: the template list a server can emit. A template that still holds one of its
    # framework's own label placeholders is refused, because the label belongs written in. The
    # default is Rails' (%{attribute}, %{model}, in either interpolation form); a binding for
    # another framework names its own.
    class TemplateCatalog
      RAILS_LABEL_PLACEHOLDERS = [/%[{<](?:attribute|model)[}>]/].freeze

      attr_reader :templates, :problems

      def initialize(label_placeholders: RAILS_LABEL_PLACEHOLDERS)
        @label_placeholders = Array(label_placeholders)
        @templates = []
        @problems = []
      end

      def add(template, source: nil, field: nil)
        issue = issue_for(template.to_s)
        if issue
          problem(source: source, field: field, issue: issue[0], fix: issue[1])
        elsif !@templates.include?(template)
          @templates << template
        end
        self
      end

      # Reported by the listing command. A problem (a message it cannot list ahead of time) fails
      # the command only under strict; advice (a field with no declared label, MSG-10) never does.
      def problem(source:, issue:, fix:, field: nil, advice: false)
        @problems << { source: source, field: field, issue: issue, fix: fix, advice: advice }
        self
      end

      def issue_for(template)
        found = @label_placeholders.lazy.map { |p| p.is_a?(Regexp) ? template[p] : (p if template.include?(p)) }
                                   .find(&:itself)
        return nil if found.nil?

        ["label placeholder #{found} left in the template", "write the field's label into the sentence"]
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
        recorder.define_singleton_method(:problem) do |issue:, fix:, field: nil, advice: false|
          catalog.problem(source: source, field: field, issue: issue, fix: fix, advice: advice)
        end
        @block.call(recorder)
        catalog
      end
    end

    def sources
      @sources ||= []
    end

    # MSG-7: list every template the sources declare, register them with +register+, and report
    # what cannot be listed. Exit 0 unless +strict+ and a problem that is not advice was reported.
    module Command
      module_function

      def run(sources:, client: nil, register: false, strict: false, out: $stdout, catalog: TemplateCatalog.new)
        sources.each { |source| source.collect(catalog) }
        catalog.templates.each { |template| out.puts "✓ #{template}" }
        catalog.problems.each do |p|
          mark = p[:advice] ? "!" : "✗"
          out.puts "#{mark} #{[p[:source], p[:field]].compact.join('.')}: #{p[:issue]} — #{p[:fix]}"
        end
        register_new(client, catalog.templates, out) if register && client
        strict && catalog.problems.any? { |p| !p[:advice] } ? 1 : 0
      end

      def register_new(client, templates, out)
        fresh = templates.reject { |template| client.message_template_known?(template) }
        client.register_phrases(fresh.map { |t| { phrase: t, category: client.messages_category } }) unless fresh.empty?
        out.puts "registered #{fresh.size} new template(s) under #{client.messages_category}"
      end
    end
  end
end
