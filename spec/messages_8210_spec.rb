# frozen_string_literal: true

require "spec_helper"
require "logger"
require "stringio"
require_relative "support/contract_fixture"

module MessageVectors
  BLOB = "c8125549cfee0f5286f79a8cbc194cd30ccd446e"
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
        expect(Langsys::Messages.resolve(row["body"], key: row["key"])).to eq(row["expected"])
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
      it "canonical entry #{entry['code']}: message is the filled template (MSG-4)" do
        expect(Langsys::Messages.fill(entry["template"], entry["params"] || {})).to eq(entry["message"])
      end
    end
  end

  describe "MSG-1 — four fixed pieces; the envelope is the app's" do
    let(:entry) { Langsys::Messages.entry(code: "too_short", template: "At least {min} characters.", params: { min: 12 }, field: "password") }

    it "renders the same entries from the default envelope and from a foreign one a resolver maps" do
      default = Langsys::Messages.envelope([entry])
      foreign = { "problems" => [{ "slug" => "too_short", "text" => entry["message"], "tpl" => entry["template"],
                                   "args" => entry["params"], "path" => "password" }] }
      mapper = lambda { |body|
        body["problems"].map do |p|
          { "field" => p["path"], "code" => p["slug"], "message" => p["text"], "template" => p["tpl"],
            "params" => p["args"] }
        end
      }
      expect(Langsys::Messages.resolve(default, key: "error.errors")).to eq([entry])
      expect(Langsys::Messages.resolve(foreign, resolver: mapper)).to eq([entry])
    end

    it "ships the langsys default envelope" do
      body = Langsys::Messages.envelope([entry])
      expect(body["status"]).to be(false)
      expect(body["error"]["errors"]).to eq([entry])
    end
  end

  describe "MSG-2 — codes are for logic" do
    it "carries the shared vocabulary in order" do
      expect(Langsys::Messages::CODES).to eq(
        %w[required invalid_type invalid_format invalid_option invalid_date not_found already_taken mismatch
           too_short too_long too_small too_large too_few too_many not_allowed already_member not_member
           already_owner expired not_available invalid]
      )
    end

    it "picks the size code by the field's type" do
      expect(Langsys::Messages.size_code(:string, :lower)).to eq("too_short")
      expect(Langsys::Messages.size_code(:string, :upper)).to eq("too_long")
      expect(Langsys::Messages.size_code(:number, :lower)).to eq("too_small")
      expect(Langsys::Messages.size_code(:number, :upper)).to eq("too_large")
      expect(Langsys::Messages.size_code(:list, :lower)).to eq("too_few")
      expect(Langsys::Messages.size_code(:list, :upper)).to eq("too_many")
    end

    it "refuses a code that is not a snake_case slug" do
      expect { Langsys::Messages.entry(code: "TooShort", template: "x") }.to raise_error(ArgumentError)
    end

    it "carries the same code in two locales and after a wording change" do
      a = Langsys::Messages.entry(code: "required", template: "The name is required.")
      b = Langsys::Messages.entry(code: "required", template: "A name is required.")
      expect([a["code"], b["code"]]).to eq(%w[required required])
    end
  end

  describe "MSG-3/MSG-4 — whole sentences; params fill markers" do
    it "keeps two per-value templates as two phrases under one code" do
      a = Langsys::Messages.entry(code: "required", template: "The password is required.")
      b = Langsys::Messages.entry(code: "required", template: "The name is required.")
      expect(a["template"]).not_to eq(b["template"])
    end

    it "omits params and equals its message when the template has no marker" do
      e = Langsys::Messages.entry(code: "mismatch", template: "The password confirmation does not match.",
                                  params: { x: 1 })
      expect(e).not_to have_key("params")
      expect(e["message"]).to eq(e["template"])
    end

    it "sends a numeric param as a JSON number" do
      e = Langsys::Messages.entry(code: "too_short", template: "At least {min} characters.", params: { min: 12 })
      expect(JSON.generate(e)).to include('"params":{"min":12}')
    end

    it "builds a text-only failure as code invalid with its text as the template (MSG-9 piece)" do
      expect(Langsys::Messages.from_text("Something went wrong.")).to eq(
        "code" => "invalid", "message" => "Something went wrong.", "template" => "Something went wrong."
      )
    end
  end

  describe "MSG-11 — the two checks a server SDK can make" do
    let(:catalog) { Langsys::Messages::TemplateCatalog.new }

    %w[attribute field label other values].each do |name|
      it "refuses a template whose marker {#{name}} carries a label" do
        catalog.add("The {#{name}} is required.", source: "UserForm", field: "email")
        expect(catalog.templates).to be_empty
        expect(catalog.problems.first).to include(source: "UserForm", field: "email")
        expect(catalog.problems.first[:issue]).to include("{#{name}}")
      end
    end

    ["The :attribute is required.", "The {{field}} is required.", "Size must be {min, number}."].each do |template|
      it "refuses #{template.inspect}: a framework placeholder or a brace that is not a marker" do
        catalog.add(template, source: "S")
        expect(catalog.templates).to be_empty
        expect(catalog.problems.size).to eq(1)
      end
    end

    it "accepts a numeric marker, and colons that are not placeholders" do
      catalog.add("At least {min} characters, by 10:30 via https://x.test.", source: "S")
      expect(catalog.templates).to eq(["At least {min} characters, by 10:30 via https://x.test."])
      expect(catalog.problems).to be_empty
    end

    it "warns once per (template, marker) when a marker is filled with a catalogued phrase, and not otherwise" do
      log = StringIO.new
      stub_authorize
      stub_translations("en-us", { "Errors" => {}, "Status" => { "Shipped" => nil } })
      client = build_client(logger: Logger.new(log).tap { |l| l.level = Logger::WARN })
      3.times do
        client.emit_message(code: "invalid", template: "The order is {status}.", params: { status: "Shipped" })
      end
      client.emit_message(code: "invalid", template: "The order is {status}.", params: { status: "A-1234" })
      expect(log.string.lines.grep(/catalogued phrase/).size).to eq(1)
    end
  end

  describe "MSG-7 — the listing command" do
    let(:out) { StringIO.new }

    def source(name, templates)
      Langsys::Messages::Source.new(name) { |cat| templates.each { |t, f| cat.add(t, field: f) } }
    end

    it "lists every template and exits 0 when there are no problems" do
      code = Langsys::Messages::Command.run(sources: [source("Signup", [["The email is required.", "email"]])],
                                            out: out)
      expect(code).to eq(0)
      expect(out.string).to include("The email is required.")
    end

    it "records a problem that is not a bad template, and exits non-zero naming it (MSG-10's unlabelled field)" do
      catalog = Langsys::Messages::TemplateCatalog.new
      catalog.problem(source: "User", field: "cc_number", issue: "validated field has no label", fix: "declare one")
      expect(catalog.problems).to eq([{ source: "User", field: "cc_number", issue: "validated field has no label",
                                        fix: "declare one" }])
      src = Langsys::Messages::Source.new("Signup") do |c|
        c.add("The email is required.", field: "email")
        c.problem(field: "coupon", issue: "custom validator with no declared template", fix: "declare its templates")
      end
      code = Langsys::Messages::Command.run(sources: [src], out: out)
      expect(code).to eq(1)
      expect(out.string)
        .to include("✗ Signup.coupon: custom validator with no declared template — declare its templates")
    end

    it "exits non-zero naming the source, the field and the fix" do
      code = Langsys::Messages::Command.run(sources: [source("Signup", [["The :attribute is required.", "email"]])],
                                            out: out)
      expect(code).to eq(1)
      expect(out.string).to match(/Signup.*email.*:attribute/)
    end
  end

  describe "MSG-7 — the langsys-messages executable" do
    require "tmpdir"
    require "open3"

    def run_cli(body)
      Dir.mktmpdir do |dir|
        file = File.join(dir, "messages.rb")
        File.write(file, body)
        exe = File.expand_path("../exe/langsys-messages", __dir__)
        Open3.capture2e("ruby", "-I", File.expand_path("../lib", __dir__), exe, file)
      end
    end

    it "exits 0 on a clean declaration and 1 on a problem, naming it" do
      clean = 'Langsys::Messages.sources << Langsys::Messages::Source.new("A") { |c| c.add("The name is required.") }'
      dirty = 'Langsys::Messages.sources << Langsys::Messages::Source.new("B") ' \
              '{ |c| c.add("The {field} is bad.", field: "x") }'
      out, status = run_cli(clean)
      expect([status.exitstatus, out]).to match([0, /The name is required/])
      out, status = run_cli(dirty)
      expect([status.exitstatus, out]).to match([1, /B\.x: marker \{field\} carries a label/])
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

    let(:entry) { Langsys::Messages.entry(code: "required", template: "The email is required.", field: "email") }

    it "MSG-6: renders under the configured category and misses under another" do
      found = contract_client(key: "r", base_locale: "es-ES")
      other = contract_client(key: "r", base_locale: "es-ES", messages_category: "Validation")
      expect(found.render_message(entry)).to eq("El correo es obligatorio.")
      expect(other.render_message(entry)).to eq("The email is required.")
    end

    it "MSG-8: registers an unlisted template after the response, never before, under Errors" do
      client = contract_client(key: "w")
      scope = client.begin_request_scope
      client.emit_message(code: "too_short", template: "At least {min} characters.", params: { min: 8 })
      client.flush_pending
      expect(contract.phrases("proj-c").keys).not_to include(["Errors", "At least {min} characters."])
      client.end_request_scope(scope)
      client.flush_pending
      expect(contract.phrases("proj-c").keys).to include(["Errors", "At least {min} characters."])
    end

    it "MSG-8: a read key registers nothing" do
      client = contract_client(key: "r")
      client.request_scope { client.emit_message(code: "invalid", template: "Nope {n}.", params: { n: 1 }) }
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
