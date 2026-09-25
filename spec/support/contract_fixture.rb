# frozen_string_literal: true

require "json"
require "net/http"
require "open3"

module Langsys
  # The fleet's API contract double (spec CONF-2), vendored byte-exact under
  # spec/contract-fixture at langsys-js-typescript tree 542f57f5. One Node process per
  # spec file; the SDK points its API base at +base_url+ through WIRE-5's seam, and a
  # test asserts on status and on the accepted state read back, never on error text.
  class ContractFixture
    TREE = "542f57f5ffcb9038db1b7411152b7e31b96cb269"
    SERVER = File.expand_path("../contract-fixture/server.mjs", __dir__)

    attr_reader :base_url, :fixture_url

    def self.start
      new.tap(&:boot)
    end

    def boot
      @stdin, @stdout, @thread = Open3.popen2("node", SERVER)
      line = @stdout.gets or raise "contract fixture exited before it was ready"
      ready = JSON.parse(line)
      raise "contract fixture not ready: #{line}" unless ready["ready"]

      @base_url = ready["base_url"]
      @fixture_url = ready["fixture_url"]
      # Drain anything the double logs so a full pipe never blocks it.
      Thread.new { @stdout.each_line { |_l| nil } }
      self
    end

    def stop
      Process.kill("TERM", @thread.pid)
      @thread.join(5)
    rescue Errno::ESRCH
      nil
    end

    def seed(document) = fixture(:post, "seed", document)
    def reset = fixture(:post, "reset", {})
    def advance(seconds) = fixture(:post, "clock", { "advance_seconds" => seconds })
    def state = fixture(:get, "state")

    # Phrases the double holds for +project+, as {[category, phrase] => translations}.
    def phrases(project)
      proj = state.fetch("projects", {}).fetch(project, {})
      proj.fetch("phrases", []).to_h { |p| [[p["category"], p["phrase"]], p["translations"]] }
    end

    def blocks(project)
      proj = state.fetch("projects", {}).fetch(project, {})
      proj.fetch("blocks", [])
    end

    private

    def fixture(verb, path, body = nil)
      uri = URI("#{@fixture_url}/#{path}")
      req = verb == :get ? Net::HTTP::Get.new(uri) : Net::HTTP::Post.new(uri, "Content-Type" => "application/json")
      req.body = JSON.generate(body) if body
      res = Net::HTTP.start(uri.host, uri.port) { |h| h.request(req) }
      raise "fixture #{path} answered #{res.code}: #{res.body}" unless res.code.to_i < 300

      res.body.to_s.empty? ? {} : JSON.parse(res.body)
    end
  end
end

# `contract: true` on a describe block starts one double for that group.
RSpec.shared_context "contract fixture" do
  before(:context) { @contract = Langsys::ContractFixture.start }
  after(:context) { @contract&.stop }
  before { @contract.reset }

  let(:contract) { @contract }

  def contract_client(key:, project: "proj-c", **opts)
    Langsys::Client.new(api_key: key, project_id: project, api_url: contract.base_url,
                        base_locale: opts.delete(:base_locale) || "en-US",
                        cache: Langsys::Cache::Memory.new, **opts)
  end
end
RSpec.configure { |c| c.include_context "contract fixture", contract: true }
