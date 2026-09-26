# frozen_string_literal: true

# Rails' own %{attribute} placeholders are test data here, not Ruby format strings.
# rubocop:disable Style/FormatStringToken

require "spec_helper"
require "logger"
require "stringio"
require_relative "support/contract_fixture"

module MessageVectors
  BLOB = "7333e3919dac43af81c6c20bfdba974efd79725b"
  PATH = File.expand_path("fixtures/server-message-vectors.json", __dir__)
  DATA = JSON.parse(File.read(PATH))
end

RSpec.describe "spec 8.2.x server messages (MSG)" do
  describe "the shared server-message vectors (langsys-js-typescript)" do
    it "is the exact blob it was vendored at" do
      expect(`git hash-object #{Shellwords.escape(MessageVectors::PATH)}`.strip).to eq(MessageVectors::BLOB)
    end

    MessageVectors::DATA["markers"].each do |row|
      it "markers: #{row['id']}" do
        expect(Langsys::Messages.markers(row["template"])).to eq(row["expected"])
      end
    end

    MessageVectors::DATA["fill"].each do |row|
      it "fill: #{row['id']}" do
        expect(Langsys::Messages.fill(row["template"], row["params"])).to eq(row["expected"])
      end
    end

    MessageVectors::DATA["resolve"].each do |row|
      it "resolve: #{row['id']}" do
        options = row["options"] || {}
        before = Marshal.load(Marshal.dump(row["body"]))
        resolved = Langsys::Messages.resolve(row["body"], key: options["key"], pieces: options["pieces"] || {})
        expect(resolved).to eq(row["expected"])
        expect(row["body"]).to eq(before)
      end
    end

    MessageVectors::DATA["render"].each do |row|
      it "render: #{row['id']}" do
        stub_authorize
        if row["catalog"].nil?
          stub_request(:get, %r{/api/translations}).to_return(status: 500, body: "")
        else
          stub_translations(Langsys::Locale.normalize_locale(row["locale"]), row["catalog"])
        end
        client = build_client(base_locale: row["locale"], messages_category: row["category"])
        expect(client.render_message(row["entry"])).to eq(row["expected"])
      end
    end

    MessageVectors::DATA["canonical_entries"].each do |entry|
      it "canonical entry #{entry['framework'][/\A\S+/]} #{entry['code']}: fill, code and field" do
        expect(Langsys::Messages.fill(entry["template"], entry["params"] || {})).to eq(entry["message"])
        built = Langsys::Messages.entry(template: entry["template"], params: entry["params"], field: entry["field"],
                                        code: entry["code"])
        expect(built).to eq(entry.except("framework", "source"))
      end
    end
  end

  describe "MSG-1 — an entry needs a template and its params; everything around it is the framework's" do
    let(:entry) do
      Langsys::Messages.entry(template: "The password field must be at least {min} characters.", params: { min: 12 },
                              field: "user.password", code: "too_short")
    end

    it "attaches entries to a framework's native error body under a configurable key, leaving the body as it was" do
      rails_body = { "errors" => { "password" => ["is too short (minimum is 12 characters)"] } }
      laravel_body = { "message" => "The given data was invalid.", "errors" => { "password" => ["The password ..."] } }
      [rails_body, laravel_body].each do |native|
        attached = Langsys::Messages.attach(native, [entry], key: "langsys")
        expect(attached.except("langsys")).to eq(native)
        expect(Langsys::Messages.resolve(attached, key: "langsys")).to eq([entry])
      end
      expect(Langsys::Messages.attach(rails_body, [entry]).keys).to eq(%w[errors messages])
    end

    it "resolves a framework's native failures through a resolver the app supplies" do
      native = { "errors" => { "password" => [{ "error" => "too_short", "count" => 12 }] } }
      resolver = lambda do |body|
        body["errors"].flat_map do |field, errors|
          errors.map do |e|
            { "template" => "The #{field} field must be at least {min} characters.",
              "params" => { "min" => e["count"] }, "field" => field, "code" => e["error"] }
          end
        end
      end
      expect(Langsys::Messages.resolve(native, resolver: resolver)).to eq(
        [Langsys::Messages.entry(template: "The password field must be at least {min} characters.", params: { min: 12 },
                                 field: "password", code: "too_short")]
      )
    end

    it "resolves renamed pieces through configuration" do
      foreign = { "failures" => [{ "sentence" => entry["template"], "values" => entry["params"],
                                   "text" => entry["message"], "path" => "user.password", "rule" => "too_short" }] }
      names = { "template" => "sentence", "params" => "values", "message" => "text", "field" => "path",
                "code" => "rule" }
      expect(Langsys::Messages.resolve(foreign, key: "failures", pieces: names)).to eq([entry])
    end

    it "needs only a template and its params: message is the filled template, and code and field are optional" do
      bare = Langsys::Messages.entry(template: "At least {min} characters.", params: { min: 3 })
      expect(bare).to eq("template" => "At least {min} characters.", "params" => { "min" => 3 },
                         "message" => "At least 3 characters.")
    end

    it "resolves an entry that carries only a template and its params, filling message as the fallback" do
      body = { "messages" => [{ "template" => "At least {min} characters.", "params" => { "min" => 3 } }] }
      expect(Langsys::Messages.resolve(body, key: "messages")).to eq(
        [{ "template" => "At least {min} characters.", "params" => { "min" => 3 },
           "message" => "At least 3 characters." }]
      )
    end

    it "resolves an entry with no template as its message alone, which a client shows without a lookup" do
      expect(Langsys::Messages.resolve({ "errors" => [{ "message" => "Bad." }] },
                                       key: "errors")).to eq([{ "message" => "Bad." }])
    end

    it "ships no envelope of its own" do
      expect(Langsys::Messages).not_to respond_to(:envelope)
    end
  end

  describe "MSG-2 — a code is the framework's own" do
    it "passes the framework's identifier through unchanged, whatever its shape" do
      ["blank", "too_short", "Illuminate\\Validation\\Rules\\Password", "value_error.missing"].each do |code|
        expect(Langsys::Messages.entry(template: "x", code: code)["code"]).to eq(code)
      end
    end

    it "carries no code when the framework has none" do
      expect(Langsys::Messages.entry(template: "x")).not_to have_key("code")
    end

    it "imposes no vocabulary and maps no rule to a code" do
      expect(Langsys::Messages.constants).not_to include(:CODES, :SIZE_CODES)
      expect(Langsys::Messages).not_to respond_to(:size_code)
    end
  end

  describe "MSG-3/MSG-4/MSG-9 — the framework's own sentence, params fill markers" do
    it "keeps two fields failing one rule as two templates" do
      a = Langsys::Messages.entry(template: "Password can't be blank", code: "blank", field: "password")
      b = Langsys::Messages.entry(template: "Name can't be blank", code: "blank", field: "name")
      expect(a["template"]).not_to eq(b["template"])
    end

    it "omits params and equals its message when the template has no marker" do
      e = Langsys::Messages.entry(template: "The password confirmation does not match.", params: { x: 1 })
      expect(e).not_to have_key("params")
      expect(e["message"]).to eq(e["template"])
    end

    it "sends a numeric param as a JSON number" do
      e = Langsys::Messages.entry(template: "At least {min} characters.", params: { min: 12 })
      expect(JSON.generate(e)).to include('"params":{"min":12}')
    end

    it "registers a text-only failure as its text, with no params and no code" do
      expect(Langsys::Messages.from_text("Something went wrong.")).to eq(
        "template" => "Something went wrong.", "message" => "Something went wrong."
      )
    end
  end

  describe "MSG-11 — the two checks a server SDK can make" do
    let(:catalog) { Langsys::Messages::TemplateCatalog.new }

    ["%{attribute} is too short", "%{model} is invalid", "The %<attribute>s field is required."].each do |template|
      it "refuses #{template.inspect}: Rails' own label placeholder, where the label should be written in" do
        catalog.add(template, source: "User", field: "name")
        expect(catalog.templates).to be_empty
        expect(catalog.problems.first).to include(source: "User", field: "name")
      end
    end

    it "refuses the placeholders a binding names for its framework" do
      laravel = Langsys::Messages::TemplateCatalog.new(label_placeholders: [":attribute", ":other", ":values"])
      laravel.add("The :attribute field is required.", source: "S")
      expect([laravel.templates, laravel.problems.size]).to eq([[], 1])
    end

    it "accepts the framework's sentence with the label written in and a {count} marker" do
      catalog.add("Password is too short (minimum is {count} characters)", source: "S")
      expect(catalog.templates).to eq(["Password is too short (minimum is {count} characters)"])
      expect(catalog.problems).to be_empty
    end

    it "warns once per (template, marker) when a marker is filled with a catalogued phrase, and not otherwise" do
      log = StringIO.new
      stub_authorize
      stub_translations("en-us", { "Errors" => {}, "Status" => { "Shipped" => nil } })
      client = build_client(logger: Logger.new(log).tap { |l| l.level = Logger::WARN })
      3.times { client.emit_message(template: "The order is {status}.", params: { status: "Shipped" }) }
      client.emit_message(template: "The order is {status}.", params: { status: "A-1234" })
      expect(log.string.lines.grep(/catalogued phrase/).size).to eq(1)
    end
  end

  describe "MSG-7/MSG-10 — the listing command reports, and fails only under strict" do
    let(:out) { StringIO.new }

    def source(name, templates)
      Langsys::Messages::Source.new(name) { |cat| templates.each { |t, f| cat.add(t, field: f) } }
    end

    it "lists every template and exits 0" do
      code = Langsys::Messages::Command.run(sources: [source("Signup", [["Email can't be blank", "email"]])], out: out)
      expect(code).to eq(0)
      expect(out.string).to include("Email can't be blank")
    end

    it "reports a message it cannot list with an actionable line, exiting 0, and 1 under strict" do
      src = Langsys::Messages::Source.new("Signup") do |c|
        c.problem(field: "coupon", issue: "message built at runtime", fix: "declare it as a translatable message")
      end
      expect(Langsys::Messages::Command.run(sources: [src], out: out)).to eq(0)
      expect(out.string).to include("Signup.coupon: message built at runtime — declare it as a translatable message")
      expect(Langsys::Messages::Command.run(sources: [src], out: StringIO.new, strict: true)).to eq(1)
    end

    it "names a validated field with no declared label as advice, never failing, even under strict" do
      src = Langsys::Messages::Source.new("User") do |c|
        c.problem(field: "cc_number", issue: "no declared label", fix: "declare one", advice: true)
      end
      expect(Langsys::Messages::Command.run(sources: [src], out: out, strict: true)).to eq(0)
      expect(out.string).to include("User.cc_number: no declared label")
    end
  end

  describe "MSG-7 — the langsys-messages executable" do
    require "tmpdir"
    require "open3"

    def run_cli(body, *flags)
      Dir.mktmpdir do |dir|
        file = File.join(dir, "messages.rb")
        File.write(file, body)
        exe = File.expand_path("../exe/langsys-messages", __dir__)
        Open3.capture2e("ruby", "-I", File.expand_path("../lib", __dir__), exe, *flags, file)
      end
    end

    it "exits 0 when it reports a problem, and 1 with --strict" do
      body = 'Langsys::Messages.sources << Langsys::Messages::Source.new("B") ' \
             '{ |c| c.add("%{attribute} is bad", field: "x") }'
      out, status = run_cli(body)
      expect([status.exitstatus, out]).to match([0, /B\.x: .*%\{attribute\}/])
      _, strict = run_cli(body, "--strict")
      expect(strict.exitstatus).to eq(1)
    end
  end

  describe "against the contract fixture", contract: true do
    before do
      contract.seed("projects" => [{ "id" => "proj-c", "target_locales" => ["es-es"],
                                     "phrases" => [{ "category" => "Errors", "phrase" => "The email is required.",
                                                     "translations" => { "es-es" => "El correo es obligatorio." } }] }],
                    "keys" => [{ "key" => "w", "project" => "proj-c", "type" => "write" },
                               { "key" => "r", "project" => "proj-c", "type" => "read" }])
    end

    let(:entry) { Langsys::Messages.entry(template: "The email is required.", field: "email") }

    it "MSG-6: renders under the configured category and misses under another" do
      found = contract_client(key: "r", base_locale: "es-ES")
      other = contract_client(key: "r", base_locale: "es-ES", messages_category: "Validation")
      expect(found.render_message(entry)).to eq("El correo es obligatorio.")
      expect(other.render_message(entry)).to eq("The email is required.")
    end

    it "MSG-8: registers an unlisted template after the response, never before, under Errors" do
      client = contract_client(key: "w")
      scope = client.begin_request_scope
      client.emit_message(template: "At least {min} characters.", params: { min: 8 })
      client.flush_pending
      expect(contract.phrases("proj-c").keys).not_to include(["Errors", "At least {min} characters."])
      client.end_request_scope(scope)
      client.flush_pending
      expect(contract.phrases("proj-c").keys).to include(["Errors", "At least {min} characters."])
    end

    it "MSG-8: a read key registers nothing" do
      client = contract_client(key: "r")
      client.request_scope { client.emit_message(template: "Nope {n}.", params: { n: 1 }) }
      client.flush_pending
      expect(contract.phrases("proj-c").keys).not_to include(["Errors", "Nope {n}."])
    end

    it "MSG-7: registers the listed templates under Errors, and a second run adds nothing" do
      client = contract_client(key: "w")
      sources = [Langsys::Messages::Source.new("Signup") { |c| c.add("The name is required.", field: "name") }]
      expect(Langsys::Messages::Command.run(sources: sources, client: client, register: true,
                                            out: StringIO.new)).to eq(0)
      before = contract.phrases("proj-c").keys
      expect(before).to include(["Errors", "The name is required."])
      second = StringIO.new
      Langsys::Messages::Command.run(sources: sources, client: client, register: true, out: second)
      expect(second.string).to include("registered 0 new template(s)")
      expect(contract.phrases("proj-c").keys).to eq(before)
    end
  end
end
# rubocop:enable Style/FormatStringToken
