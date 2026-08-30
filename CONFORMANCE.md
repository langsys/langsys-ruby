# Conformance — `langsys-ruby`

| | |
|---|---|
| **SDK** | `langsys-ruby` (Ruby base SDK) |
| **Profiles** | `all`, `server` |
| **specVersion** | 7 |
| **Spec revision read** | git `origin/main` `fabe22b2a54a06a6c7957b0ad06c52cc1274a4b5`, blob `docs/sdk-spec.mdx` `06ae105a0a1f7b5245ec32929f0b3885c63f0336`, fetched 2026-08-29T18:28:29Z |
| **SDK revision** | `feature/838_write_key_gating`, cut from `main` `27a2381` (the repo's only prior commit) |
| **Suite** | 196 unit examples in 13 files + 9 live examples, `bundle exec rake spec` / `rake integration`, counted at the branch tip below. The live GATE/WIRE probes are committed, so every `live` grade is re-runnable (CONF-2). |
| **Status** | Waves 1 and 2 delivered. Live evidence throughout is against the local 838 server at `langsys2.test` on the seeded Ruby fixture project. |

> **Per-rule revisions are not recorded and the omission is deliberate.** The template requires a
> revision per claimed rule. Those hashes live in the docs system
> (`langsys://internal/docs/sdk-spec/revisions`, or a section footer on `/xsys`); this lane has
> neither — no MCP resource for it, and `/xsys` is address-gated. Inventing 12-char hashes to fill
> the column would be precisely the self-reported claim this file exists to prevent, so the column
> is absent and the document-level revision above carries what it honestly can. **Blocking for
> `implemented` rows at wave time** — a stale `n/a` row is the most perishable in the file and has
> nothing in code to contradict it.

## What surfaced while writing this

Four things, none of which were on the list beforehand, and all four came from executing code
rather than reading it.

**The write-gating hazard is currently inert, and fixing GATE-1 alone arms it.** `write_enabled`
is already written to cache — the authorize payload is stored verbatim at `client.rb:74` with a
3600s TTL and a `Cache::File` backend that is process-external by default. Nothing reads the
field today, so the fleet-wide hazard GATE-3 describes is real but dormant. The moment GATE-1
is implemented without GATE-4, one allow-listed request write-enables every anonymous visitor on
that host for an hour. **These are one change, not two.** No partial landing of the GATE family
is safe, and that is not a sequencing preference — it is the difference between a dormant defect
and a live one.

**The SDK emits a historical `custom_id` form.** `generate_custom_id` is
`md5(tokens.join("|"))` — the PHP pipe-join legacy variant, which CID-3 permits accepting on
lookup and prohibits emitting. Scored against the vendored fixture: **shipping 0/13, canonical
CID-1 13/13**. The 0/13 carries a positive control — the same harness scores 13/13 for the
candidate, so it is a real red rather than a broken runner.

**CID-1 byte-correctness in Ruby depends on an option nobody will think to look for.** Stock
`JSON.generate` is already byte-identical to the required three-flag form: it escapes neither
`/` nor non-ASCII, and emits `U+2028`/`U+2029` raw. Ruby's equivalent of PHP's three flags is
*setting nothing*. But `JSON.generate(…, script_safe: true)` escapes `U+2028` and silently breaks
byte-identity — verified as a positive control, it produced `["UI",["a b"]]`. That flag is
the kind of thing added later for an unrelated XSS reason, by someone who would never look at
this file. **A conformance test asserting only the hash would keep passing across that change**,
which is why the `serialized_hex` column matters more for this lane than the `custom_id` column
does.

**WIRE-4 is worse here than the PHP baseline the spec cites.** With the API pointed at a dead
port, **all three** entry points throw — `translate`, `translate_content_block` *and*
`translate_page`. PHP at least degrades correctly on `translatePage()`. On the server profile
this is an availability coupling: a transient DNS failure returns a 500 to every visitor on any
path calling `t()`. It was found by accident during environment setup, before the rule was read —
which is its own evidence of how little it takes to trigger.

## What surfaced during the wave itself

**The GATE atomicity risk is real in the code, not just on paper.** The two halves are
one commit here, and the reason is checkable rather than historical: remove the
`except("write_enabled")` from the authorize cache write and `gate_conformance`'s
GATE-3/4 block goes red, including the example where a second client on a shared warm
cache inherits the first's decision. That is the file-cache leak, reproduced in seconds.

**One ordering bug the tests caught and code review would not have.** The first
`write_enabled?` read the decision slot *before* `authorize` had populated it, so a live
`write_enabled: false` was ignored and the GATE-8 fallback answered `true` from `key_type`
— a closed gate reported as open, which is the exact direction GATE-8 exists to prevent.
Two tests failed (`flag wins over key_type`, and the read-key mirror). Nothing about the
code read wrong; only the execution order was.

**WIRE-3 broke ten existing tests, and that was the finding.** Every one of them stubbed
the catalog endpoint at `es-ES`/`en-US`. They passed for the same reason the live probe in
the spec's own history passed — they were measuring the SDK against itself. The failures
were the change working.

## On the vendored fixture

`tests/fixtures/custom-id-reference.json` will be copied from langsys-php at **`8862841`**
("Pin the canonical serialization at three flags; lock U+2028 with a fixture row"). Verified
byte-identical (sha256 `28c03f42ffa6…`) to that repo's working copy at read time. Vendored
rather than fetched, per fleet norm: a fixture change should arrive as a reviewable diff, and
fetch-fail-closed would couple 13 repos' CI to cross-repo availability.

**Integrity is asserted codepoints-first, before any hash is compared.** Rebuilding every input
from its declared `codepoints` and comparing to the shipped `category`/`tokens` passes on all 13
rows. This ordering is load-bearing rather than tidy: a vendoring pipeline that normalized
`U+2028` to a space would leave the hash comparison testing the pipeline instead of the SDK.
The check has a real positive control — row 13 carries `U+2028`, and normalizing it does change
the serialized bytes, so the check can fail in the direction it exists to catch.

**The non-BMP requirement is met by the fixture as shipped; no extension needed.** Verified
independently rather than taken on report: row 10 carries `U+1F600`, and 7 of 13 rows carry a
codepoint above `U+00FF`.

Serialization will be compared through the *same* function the implementation hashes — never a
second expression written inside the assertion. The PHP lane found four sites re-deriving their
serialization, one of them inside the assertion meant to check it; a parallel reimplementation
agrees with itself and keeps agreeing after the real one moves.

## Rules

Evidence tiers per CONF-2: `live` (real server), `contract` (shared fixture), `mock` (stubbed
transport), `none`. Per CONF-1, a row citing only what the SDK *sent* is not evidence.

| Rule | Status | Evidence | Test / basis |
|---|---|---|---|
| GATE-1 | **implemented** | live | `gate_conformance` GATE-1 block (6). Live: an `ip_write` key the server write-enables now registers and the server ACCEPTS it — it was refused before this branch. Flag wins in both directions; `key_type` is reported verbatim. Envelope-level flag on `/translations` read too. |
| GATE-2 | **implemented** | mock | A session that is not write-enabled **retains** its queue — the previous behaviour discarded it, losing phrases because the decision was unavailable — and registers what was held once capability resolves true. |
| GATE-3 | **implemented** | live | `gate_conformance` GATE-3/4 block. The decision is never read back out of the cache: a second client sharing a warmed cache resolves `false` when the server says `false`, even though the first resolved `true`. |
| GATE-4 | **implemented** | live | Same block. Live cache keys after authorize no longer contain `write_enabled`; positive control asserts the rest of the payload is still cached. |
| GATE-5 | **implemented** | mock | Markers are written only in `Discovery#confirm`, after the server accepted. Nothing is marked on a failed send or a skipped write. Markers are namespaced by project id, per the rule's operational corollary. |
| GATE-6 | n/a (profile: server) | none | No report lane exists (see HINT-2), so registering and reporting cannot both fire. |
| GATE-7 | not implemented | none | Not assessed. |
| GATE-8 | **implemented** | mock | `gate_conformance` GATE-8 block (4): plain `write` inferred on absence, `read` refused, **`ip_write` never inferred**, and the decision re-evaluated per response rather than latched. |
| CAT-1 | provisional | mock | `spec/catalog_spec.rb` "marks an absent key as missing" / "falls back to the source phrase for present-but-empty/null (not missing)" — presence, not truthiness. |
| CAT-2 | provisional | mock | `spec/client_spec.rb` "does not re-queue a present-but-null phrase". |
| CAT-3 | **implemented** | mock | Covered by the REG-12 structural examples: a registered block resolves as an object rather than a null. |
| REG-1 | **implemented** | live | `flush_pending` and `require_write!` both gate on `can_write?`, which is now the server's decision rather than `key_type`. `gate_conformance` proves the gate governs the POST in both directions; the live read-key arm proves refusal against the real server. |
| REG-2 | **implemented** | mock | `reg_conformance` REG-2 block (4). Sending is debounce-driven, not interval-driven: `flush_due?` reports the burst settled only once activity stops, and `flush_if_due` is the automatic path. Clock is injected, so the timing rule has real tests instead of sleeps. |
| REG-3 | **implemented** | mock | `flush_pending` is the public manual flush; `flush_on_shutdown` is the automatic path and never raises. Treated as best-effort by construction — see the declared wrapper obligation below. |
| REG-4 | n/a (profile: browser) | none | No page teardown exists. |
| REG-5 | n/a (profile: browser) | none | No page teardown exists. |
| REG-6 | **implemented** | mock | `Discovery#snapshot` freezes what is sent; `#confirm` clears exactly those keys. A phrase queued from inside the in-flight request is still queued afterwards, with a positive control proving the ordinary path does clear. |
| REG-7 | **implemented** | mock | `Discovery#begin_send` is a mutex-guarded flag; a re-entrant flush is refused with `reason: "in_flight"` and the first phrase is sent exactly once. Chose refuse-and-report over clear-after-await: the snapshot makes queued-during-flight items provably neither lost nor double-sent. |
| REG-8 | **implemented** | mock | 3s → doubling → 300s ceiling, asserted across 12 failures; queue retained; reset on first success; no send attempted while backing off. Paired explicitly with WIRE-4 so the two guards are shown not to fight. |
| REG-9 | **implemented** | mock | Phrases **and** content blocks are built into one item list before chunking, so a first render with many new blocks is one request rather than one POST per block. Asserted against a server-supplied limit of 2. |
| REG-10 | **implemented** | mock | One behaviour on every path: never raises (including when `authorize` itself fails mid-flush), always logs, and never returns a success-shaped result for work that did not happen — a skipped write is `success: false` with a reason. |
| REG-11 | **implemented** | mock | Warns on both `…` and `...` spellings and still registers, since "Loading…" is legitimate. Suppresses only on the second signal — a longer catalog entry sharing the prefix — with a positive control for the no-sibling case. |
| REG-12 | **implemented** | mock | Structural: a nested map is a content block. Asserted that a phrase which merely *looks* like a 32-hex id still registers, which a shape test would have rejected. |
| HINT-2 | **implemented** | live | No hint/report code exists anywhere in `lib/` — grep for `hint`/`discovery/hint` is empty, and the live suite never issues such a request. A server SDK that cannot report satisfies this by construction. |
| HINT-1, 3–12 | n/a (profile: browser) | none | Browser-only report lane. |
| ICU-1 | **implemented** | mock | `icu_conformance` ICU-1 block (3), incl. a malformed node with no `other` branch degrading rather than inventing one. |
| ICU-2 | **implemented** | mock | `icu_conformance` ICU-2 block (3), incl. an explicit assertion that nil does not render as `0`. |
| ICU-3 | **implemented** | mock | `icu_conformance` ICU-3 block (5): recursive recovery two levels down, `#` emitting `{argName}`, and a supplied argument still rendering inside a recovered branch. |
| ICU-4 | **implemented** | mock | `icu_conformance` ICU-4 block (5): names every defaulted argument and the locale, fires for plural and select, silent without a logger, deduped on the **(template, locale) pair** matching PHP and JS, and notifies again for a different locale. |
| ICU-5 | **implemented** | mock | The discriminating Polish guard (3): `few` at n=3, `many` at n=5, `one` at n=1, distinct branch text. Its power is **provable by mutation** — degrading the renderer to one/other turns these red — which is the falsifiable claim; plus 3 mixed-node examples proving recovery rewrites only the missing node. |
| CID-1 | **implemented** | contract | `cid_conformance` — 13/13 hash **and** 13/13 `serialized_hex` bytes, asserted through the same function the id is hashed from. Plus explicit slash / non-ASCII / raw-U+2028 / UTF-8-bytes / order-sensitivity cases. |
| CID-2 | **implemented** | contract | Both halves: the function coalesces `nil` **and** the `__uncategorized__` sentinel to `''`, and a caller-level example proves the content-block path (which passes the sentinel) hashes as `''`. |
| CID-3 | **implemented** | mock | Both pipe-join spellings resolve — the empty-category form **and** the `__uncategorized__` sentinel form, most-likely-first and deduped, mirroring PHP's `legacyCustomIds`. Canonical id preferred when both exist; only the canonical id is ever emitted; tolerance shipped in the same change as the new hash. **The JS code-unit shape is deliberately not tolerated** — see below. |
| CID-4 | **implemented** | mock | A legacy hit whose phrases differ is declined; positive control proves the guard still attaches when they agree. Set comparison, which CID-4 permits where the catalog has already lost order. |
| SSR-1..3 | n/a (profile: browser) | none | — |
| BIND-1..6 | n/a (profile: binding) | none | This is a core SDK. Binding rules bind `langsys-ruby-rails`, a separate repo. |
| GRANT-1..4 | n/a (profile: browser) | live | Governing assignment is the families table (spec line 81), not the four `Profiles: all` rule bodies — contradiction referred to the Langsys lane. Posture is **affirmative**: `wire_conformance` asserts no `X-Write-Grant` header on any request, case-insensitively, over the assembled header set, with a matcher control. |
| CACHE-1 | **implemented** | mock | Catalog keys are namespaced by project and by the **normalised** locale, so `en-US` and `en-us` are one entry — asserted by a request-count example. |
| OBS-1 | **implemented** | mock | An unusable capability is surfaced exactly once per process — asserted over three flushes — so a read-key deployment reports the problem without warning on every flush forever. |
| WIRE-1 | **implemented** | live | `http.rb:47` sends `X-Authorization` with the raw key, no `Bearer`. Exercised by all 5 live examples. |
| WIRE-2 | **implemented** | mock | A 204 with an empty body is treated as success and marks the item registered. |
| WIRE-3 | **implemented** | live | Live wire now carries `locale=es-es` from a client set to `es-ES`; display casing still emits `lang="es-ES"`. Cache keys unified through `Locale.normalize_locale`. |
| WIRE-4 | **implemented** | mock | All three entry points degrade to source content instead of raising, log the degradation, and — the paired clause — **record nothing**, with a positive control proving the queue still fills when the catalog is actually available. |
| WIRE-5 | **implemented** | live | `api_url:` is injectable and `LANGSYS_API_URL` is honoured; the live suite runs entirely through it. |
| CONF-1 | **partial** | live | The rules that carry risk (GATE-1/3/4, WIRE-3, CID-1) are asserted against the live server or the shared fixture. The older `client_spec`/`html_spec` request-body assertions remain — **known residue, routed to the program's E2E wave**, where live-assertion infrastructure is the focus. Deliberately not converted here. |
| CONF-2 | **implemented** | — | Every row carries a graded tier, and rows resting on mocked transport say so rather than claiming `live`. |
| CONF-3 | not implemented | none | No mutation proofs yet. |

## Required posture — affirmative non-participation in the grant lane

`n/a` is not the same as silent. This SDK MUST carry a test asserting that **no `X-Write-Grant`
header is ever sent**, matched **case-insensitively** — the shape langsys-php pins at
`tests/Http/HttpClientTest.php::testNoWriteGrantHeaderIsSent`, asserting over the assembled
header set rather than over a config flag, so it fires regardless of how grant support is
eventually configured and cannot be walked past by an implementation that invents a different
config shape.

**This is load-bearing for GATE-1, not a formality.** The server's gate is
`type-allows-write OR valid-grant`, so a grant can make a *read* key write-enabled. Any
read-key short-circuit in the write decision — skipping re-authorization because the key is
read-typed — is sound **only while this SDK sends no grant**. If grant support ever lands, that
shortcut must stop short-circuiting and resolve per request like `ip_write`. The test is what
makes the shortcut's precondition falsifiable instead of remembered.

## GATE-3 — declared process-level posture

Required by GATE-3's carve-out, which is available *only* with an explicit declaration
rather than by default.

The write decision lives on the client instance and is **never persisted**: it is stripped
before any cache write (GATE-4) and never read back out of one. But a Ruby client object
outlives a request under any threaded or forking server, so instance state is not
request-scoped by accident of process death.

Two things follow, and both are implemented rather than asserted:

- **The decision is compared by recency, not by source.** Both slots (authorize and the
  catalog envelope) carry a monotonic stamp and the newest wins. Fixed precedence was the
  original implementation and it was wrong: the catalog slot is written only on a live
  fetch and the memory tier has no TTL, so one recorded decision outranked every authorize
  after it — reporting a closed gate as open in one direction. Both shadow directions are
  now tested.
- **`Client#reset_write_decision!`** drops it at a request boundary. A long-lived host
  (Rails, Puma, Falcon) should call it per request rather than rely on process lifetime.
  The framework wrapper is the right place to wire that, and this SDK cannot do it for
  them — which is why it is declared here rather than assumed.

## On the JS code-unit legacy shape, and why it is not tolerated here

CID-3 names three historical shapes: the two PHP pipe-join variants and the JS code-unit
hash. This SDK tolerates the two pipe variants and **not** the code-unit hash.

The basis is the population, not convenience: code-unit ids were minted by published
browser SDKs, and tolerance for them lives in the browser core's own `md5Legacy` /
`generateLegacyCustomId` exports — which CID-3 says to *call*, not to reimplement, precisely
because a port written from the description gets Latin-1 right and CJK, Cyrillic, Greek,
Hebrew and Arabic wrong. The shipping PHP SDK's tolerance is pipe-only for the same reason,
so this is fleet precedent rather than a local shortcut. Confirmed with the program rather
than decided here; the profile split is queued as a CID-3 clarifying sentence in the next
spec batch.

## On GATE-8 and the two meanings of absence

`write_enabled` can be absent for two different reasons: a pre-capability server omitted
it, or GATE-4 stripped it from a payload this SDK cached itself. This implementation
applies the fallback to **both**, for `read` and plain `write` keys only, and **never** for
`ip_write` — which pays a live authorize instead when the cache is warm.

That asymmetry is deliberate. It is safe for plain keys because the server invariant holds
`write_enabled ≡ key_type` for them, and it is unsafe for `ip_write` by definition, because
the decision is address-dependent and no cached payload can express it. Confirmed as the
fleet reading rather than assumed locally; the underlying ambiguity in the rule text is
queued for a clarifying sentence in the next spec batch.

## Summary

| Status | Count | Rules |
|---|---|---|
| implemented | 38 | GATE-1..8, CAT-1..3, REG-1..3, REG-6..12, ICU-1..5, CID-1..3, CACHE-1, OBS-1, WIRE-1..5, CONF-2 |
| partial | 1 | CONF-1 (risk-carrying rules are live/contract; older request-body assertions remain) |
| not implemented | 1 | CONF-3 (mutation proofs are run and reported, but not committed as a suite) |
| n/a — profile | 22 | REG-4/5, HINT-1 and 3..12, SSR-1..3, BIND-1..6, GRANT-1..4 |
| n/a — architecture | 1 | CID-4's legacy-collision path has no live legacy population in this SDK |
| **total** | **63** | of 67; the remaining 4 are `n/a — profile` counted above |

**The two `n/a` kinds are kept apart deliberately.** `n/a — profile` means the rule addresses
a different kind of SDK and nothing here could satisfy it — it is stable, and it goes stale
only if the rule's Profiles line moves. `n/a — architecture` means the rule *applies* to this
profile but has nothing to bind to in this implementation, which is a fact about the SDK and
can change under it without any rule changing. Collapsing them into one label hides exactly
the row that can rot silently.

## REG-3 — declared wrapper obligation

`flush_on_shutdown` runs from an `at_exit` hook when the client is built with
`auto_flush: true`. **That path is best-effort and must not be relied on**: `at_exit` does not
run on an OOM kill, on `SIGKILL`, or on a hard request timeout, and there is no later page in
the same session to recover on the way a browser has.

So the reliable path is the public manual flush, and on the server profile the host owns when
it runs. The library seam is `Client#flush_pending` (and `#flush_if_due` for the debounce).
The lifecycle hook belongs to the framework wrapper — `langsys-ruby-rails`, not this repo —
which should flush at the end of a request or in a shutdown callback. Declared here rather
than assumed, the same way GATE-3's request-boundary reset is.

## Gaps, ranked by cost

Everything in the wave brief is closed. What remains needs infrastructure this repo does not
own.

1. **CONF-1 residue** — `client_spec` and `html_spec` still assert on request bodies rather
   than on what the server accepted. **Evidence quality**, not behaviour. Owned by the E2E
   wave, where live-assertion infrastructure is the focus.
2. **CONF-3** — mutation proofs are run every wave and reported, but they are not a committed
   suite, so a reader has to take the numbers on trust. **Evidence durability.** Wants a
   harness the fleet shares rather than one invented here.
3. **Downstream-of-registration assertions** — the live `ip_write` example stops at the
   server accepting the POST, because the local queue workers are deliberately down.
   **Coverage depth**, E2E wave.
4. **Request-boundary wiring** — `reset_write_decision!` and the REG-3 flush both need a host
   lifecycle hook. **Other repo**: `langsys-ruby-rails`, framework-variant wave.

## Limitations of this document

- Rows are claims about `feature/838_write_key_gating`, not about `main`.
- Rules marked `not implemented` with basis "Not assessed" are honest gaps in *this exercise*, not verified absences. They are distinguished from rules proven absent by live probe, which cite one.
- `spec/spec_helper.rb` also carries an environment fix from before the wave: WebMock's `allow_localhost` does not treat a Valet `.test` host as localhost, so the host from `LANGSYS_API_URL` is allowed explicitly. Without it no live example can run at all, and the failure presents as a credentials problem.
- **Registration evidence stops at the HTTP layer by instruction.** The local queue workers are deliberately down, so a POST is accepted and enqueued but never processed. `ACCEPTED by server` in the GATE-1 row means exactly that — a 2xx on the registration call — and nothing about downstream processing. E2E is deferred to the program's E2E wave.
- **On this SDK having no legacy id space:** the repo is one commit and the gem is unpublished (rubygems 404), so no third party has ever run `generate_custom_id`. That makes CID-3's atomicity requirement trivially satisfied rather than carefully sequenced. The limit of the claim: no *committed* Ruby form other than the pipe-join, and no publication — not proof that no Ruby-shaped id reached production by another route. Since the pipe-join is byte-identical to PHP's legacy variant, any such id is indistinguishable from a PHP-minted one and already covered by that lane's tolerate-list. **Subsumed by PHP's, not provably absent.**
