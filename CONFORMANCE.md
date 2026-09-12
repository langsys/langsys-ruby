# Conformance — `langsys-ruby`

| | |
|---|---|
| **SDK** | `langsys-ruby` (Ruby base SDK) |
| **Profiles** | `all`, `server` |
| **specVersion** | 8 |
| **Spec revision read** | git `origin/feature/838_write_key_gating` `483f98fb9c22155fdd51e0946239556470f57936`, blob `docs/sdk-spec.mdx` `b657b490f07615b889081c0ac5244ec4bd73bf81`, read 2026-09-11. Re-derive with `git -C ../langsys2 ls-tree origin/feature/838_write_key_gating docs/sdk-spec.mdx`. Docs-site publication pending, so this rows against the blob. |
| **SDK revision** | `feature/838_write_key_gating`, cut from `main` `27a2381` (the repo's only prior commit) |
| **Suite** | 300 unit examples in 15 test files + 9 live examples, `bundle exec rake spec` / `rake integration`, counted at the branch tip below. The live GATE/WIRE probes are committed, so every `live` grade is re-runnable (CONF-2). |
| **Status** | Waves 1, 2 and the canonicalization lane delivered. Live evidence throughout is against the local 838 server at `langsys2.test` on the seeded Ruby fixture project. |

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

**A near-vacuous guard hid a live availability hole for two waves.** `Http#perform`
rescued an enumerated list of socket errors, so `OpenSSL::SSL::SSLError` and
`Net::HTTPBadResponse` — both direct `StandardError` subclasses, under neither
`SystemCallError` nor `Net::ProtocolError` — escaped unwrapped, past every downstream guard,
which all rescue `Langsys::Error` only. A cert rotation or an interfering proxy would have
turned every `t()` page into a 500: the precise availability coupling WIRE-4 exists to
prevent, while this file claimed WIRE-4 implemented.

The rescue list is the defect; the test is why it survived. My WIRE-4 guard stubbed the
**POST** to raise — and `t()` never POSTs. It could not have failed however wide the hole
was. The rewritten guards aim protocol-layer failures at the **GET**, which is the request
every entry point actually makes. The fix is `rescue StandardError` scoped to the single
line `http.request(request)`, where "any exception here" and "the transport failed" are the
same statement; the class name is kept in the message so degrading does not cost the
diagnosis.

**The summary table was a hand-maintained tally that reconciled with nothing.** It
miscounted, listed rules as implemented that its own table graded `n/a` and `not
implemented`, and had no bucket for two statuses the table used. It is now computed from
the table and enforced by `spec/conformance_doc_spec.rb`, so the document fails the build
rather than the reader.

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
| GATE-6 | n/a (architecture) | none | Profiles: `all`, so it binds — but this SDK has no report lane at all (HINT-2), so registering and reporting cannot both fire and there is nothing to branch. Architecture, not profile: if a report lane were ever added here, this row becomes live with no rule having changed. |
| GATE-7 | not implemented | none | Not assessed. |
| GATE-8 | **implemented** | mock | `gate_conformance` GATE-8 block (4): plain `write` inferred on absence, `read` refused, **`ip_write` never inferred**, and the decision re-evaluated per response rather than latched. |
| CAT-1 | provisional | mock | `spec/catalog_spec.rb` "marks an absent key as missing" / "falls back to the source phrase for present-but-empty/null (not missing)" — presence, not truthiness. |
| CAT-2 | provisional | mock | `spec/client_spec.rb` "does not re-queue a present-but-null phrase". |
| CAT-3 | **implemented** | mock | Covered by the REG-12 structural examples: a registered block resolves as an object rather than a null. |
| REG-1 | **implemented** | live | `flush_pending` and `require_write!` both gate on `can_write?`, which is now the server's decision rather than `key_type`. `gate_conformance` proves the gate governs the POST in both directions; the live read-key arm proves refusal against the real server. |
| REG-2 | **implemented** | mock | Sending is debounce-driven, not interval-driven: `flush_due?` reports ready once activity settles, `flush_if_due` is the automatic path, and the clock is injected so the timing rule has real tests rather than sleeps. A `MAX_WAIT_SECONDS` ceiling keeps a continuous trickle from starving the debounce — each new miss would otherwise push the window out forever. |
| REG-3 | **implemented** | mock | `flush_pending` is the public manual flush; `flush_on_shutdown` never raises, **bypasses the backoff for one final attempt**, and logs an abandonment with the item count if that fails. A backed-off queue was previously dropped at shutdown with no request and no log — permanent loss, unrecorded. See the declared wrapper obligation below. |
| REG-4 | n/a (profile: browser) | none | No page teardown exists. |
| REG-5 | n/a (profile: browser) | none | No page teardown exists. |
| REG-6 | **implemented** | mock | `Discovery#snapshot` freezes what is sent; `#confirm` clears exactly those keys. A phrase queued from inside the in-flight request is still queued afterwards, with a positive control proving the ordinary path does clear. |
| REG-7 | **implemented** | mock | `Discovery#begin_send` is a mutex-guarded flag; a re-entrant flush is refused with `reason: "in_flight"` and the first phrase is sent exactly once. Chose refuse-and-report over clear-after-await: the snapshot makes queued-during-flight items provably neither lost nor double-sent. |
| REG-8 | **implemented** | mock | 3s → doubling → 300s ceiling, asserted across 12 failures; queue retained; reset on first success; no send attempted while backing off. Paired explicitly with WIRE-4 so the two guards are shown not to fight. |
| REG-9 | **implemented** | mock | Phrases **and** content blocks are built into one item list before chunking, so a first render with many new blocks is one request rather than one POST per block. Asserted against a server-supplied limit of 2. |
| REG-10 | **implemented** | mock | One behaviour on every path: never raises — including when `authorize` fails mid-flush (`decision_unavailable`, now committed) and including protocol-layer failures, which previously escaped `Http#perform` unwrapped — always logs, and never returns a success-shaped result for work that did not happen. |
| REG-11 | **implemented** | mock | Warns on both `…` and `...` spellings and still registers, since "Loading…" is legitimate. Suppresses only on the second signal — a longer catalog entry sharing the prefix — with a positive control for the no-sibling case. |
| REG-12 | **implemented** | mock | Structural: a nested map is a content block. Asserted that a phrase which merely *looks* like a 32-hex id still registers, which a shape test would have rejected. |
| HINT-2 | **implemented** | live | No hint/report code exists anywhere in `lib/` — grep for `hint`/`discovery/hint` is empty, and the live suite never issues such a request. A server SDK that cannot report satisfies this by construction. |
| HINT-1, 3–12 | n/a (profile: browser) | none | Browser-only report lane. |
| ICU-1 | **implemented** | mock | `icu_conformance` ICU-1 block (3), incl. a malformed node with no `other` branch degrading rather than inventing one. |
| ICU-2 | **implemented** | mock | `icu_conformance` ICU-2 block (3), incl. an explicit assertion that nil does not render as `0`. |
| ICU-3 | **implemented** | mock | `icu_conformance` ICU-3 block (5): recursive recovery two levels down, `#` emitting `{argName}`, and a supplied argument still rendering inside a recovered branch. |
| ICU-4 | **implemented** | mock | `icu_conformance` ICU-4 block (5): names every defaulted argument and the locale, fires for plural and select, silent without a logger, deduped on the **(template, locale) pair** matching PHP and JS, and notifies again for a different locale. |
| ICU-5 | **implemented** | mock | The discriminating Polish guard (3): `few` at n=3, `many` at n=5, `one` at n=1, distinct branch text. Its power is **provable by mutation** — degrading the renderer to one/other turns these red — which is the falsifiable claim; plus 3 mixed-node examples proving recovery rewrites only the missing node. |
| TOK-1 | **implemented** | contract | `tok_conformance` TOK-1 block. The spec's own test (one sentence in script/style/template/noscript plus once in ordinary markup → exactly one phrase) plus a per-element example. **`<template>` is a real vector here, unlike in the JS family**: parse5 hangs template content off a separate fragment so a walker emits nothing either way, but libxml2 puts it in the tree, so omitting it from the exclusion list would leak. Excluded by element NAME — see the note below on why the previous pass was accidental. |
| TOK-2 | **implemented** | contract | **Four** token paths, not three: the collapse, the re-emit lead/trail detector, `<title>`, and `meta[content]` — the last found by review because it neither collapsed nor trimmed, so a grep for the wrong handling could not see it. All three vectors, written as escapes never literals: internal `U+00A0` collapsing to the same id as `U+0020`; leading **and** trailing, which a collapse-only fix leaves behind; and a whitespace-only node producing **no** token, which is the count case that moves block ids. Control: text that genuinely differs keeps two ids. Fixture rows `nbsp-in-text`, `attr-nbsp`, `line-separators`. |
| TOK-3 | **implemented** | contract | Twenty-seven attributes, verified **literally** against `langsys-php-sdk src/Html/HtmlParser.php:26-60` and against the spec text — identical in content *and* order, diffed rather than eyeballed. Plus the spec's test: three listed attributes on one element produce three phrases in list order, two unlisted produce none. |
| TOK-4 | **implemented** | contract | The same string as a text node and as a `title` yields one id, and `U+00A0` collapses inside an attribute value too. Fixture rows `attr-multiline`, `attr-nbsp`. |
| TOK-5 | **implemented** | mock | `{name}` and `%name%` interpolate to the same output, including a template mixing both. An unrecognised form is left literal. **Deliberate narrowing:** `%name%` is substituted only when the argument is supplied — ordinary prose is full of percent signs and a greedy rule turns `50%off20%` into a slot — so an unmatched escape stays exactly as authored rather than being rewritten into a gap marker. |
| MARK-1 | **implemented** | mock | **Both halves.** A rendered block host carries `data-ls-contentblock`, stamped whether or not the block resolved, since the identity is wanted most when it did not; asserted by **re-deriving** the id with the tokenizer rather than reading back what the renderer just wrote. A rendered single-phrase host carries `data-ls-phrase` naming the SOURCE phrase, not the rendered text — that half was missing when this row first claimed `implemented`, found by review. |
| MARK-2 | **implemented** | mock | All three suffixes in both spellings, on **both** tokenizing paths — the leaf path and the explicit content-block host path, which handed raw inner HTML to the tokenizer and folded a marked child's text into the block id until review caught it. `category`, `contentblock` and **`phrase`** — the last is the one the rule's own Test names, and it was missing when this row first claimed `implemented` with "both directions tested", which was true only of the other two. A marked host is left whole: not re-split, and nothing queued for its text, with an unmarked control proving the recognition is not just "tokenize nothing". |
| SRV-1 | **implemented** | mock | Asserted on the **served bytes**, not a post-hydration DOM. Control phrase absent from the catalog emits the base language and is reported as a miss, which is what separates this from rendering a catalog that happened to be complete. |
| SRV-2 | **implemented** | mock | Evidence is `srv_conformance` **"keeps two renders interleaved MID-RENDER"**: a two-party barrier inside `walk_block` holds both threads until both are inside a render, so they are provably suspended mid-walk at once, and the barrier's meeting is itself asserted so a silent degradation to sequential renders fails rather than passes. Pinned by moving `@locale` to a class variable, which reds exactly that example. **The 30-iteration loop is a supporting row, not the evidence** — an earlier version of this cell cited it as the proof, and it was measured as never once switching threads inside a render; it now asserts all 30 results per thread rather than the survivor, and proves cross-client isolation between renders. A third example proves no process-global holds per-request state. |
| SRV-3 | **implemented** | mock | Three assertions, per the rule: the registration POST does **not** occur during the render (order of events, not merely that collection happens), a read-only key pushes nothing, and a write key on the same render pushes — the positive control without which the read-only half passes against an SDK that never pushes at all. |
| SRV-4 | **not implemented** | none | **Rowed against the rule body, not the brief.** The Profiles line names `server` FIRST — only the synchronous seed belongs to the browser core — so this does not fall away on profile, and my earlier `n/a (profile: browser)` claimed a pass for work that does not exist. Verified: nothing in `lib/` emits a catalog for a client to pick up (`grep -riE '__LANGSYS|window\.|hydrat|<script'` finds only a TOK-1 comment). `get_translations` is public so an integrator could serialise it, but this SDK neither does nor documents it. Matching langsys-php, which holds the same row at `not implemented` pending a normative clarification: the rule's author has confirmed it over-binds a page-translation server SDK, and `translate_page` emits terminal HTML that nothing hydrates. Held here until the rule is corrected, that being the more honest of the two while the published text reads as it does. |
| SRV-5 | n/a (architecture) | none | **Also not for the profile reason** — the Profiles line names `server`, so this falls away on MECHANISM. SRV-5 governs component child capture: a re-entrant render registering 2^n copies of one miss, or a `Suspense` fallback keying a block on a loading spinner. This SDK walks a DOM once and has no component model, no re-entrant render and no lazy children, so neither failure has a site here. The mechanism is named so the claim is checkable rather than asserted — and unlike a profile row, it can rot under us if a component surface is ever added. |
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
| WIRE-4 | **implemented** | mock | All three entry points degrade instead of raising, log it, and record nothing; positive control proves the queue still fills when the catalog is available. **Now asserted at the protocol layer too** — `OpenSSL::SSL::SSLError`, `Net::HTTPBadResponse` and `EOFError` aimed at the GET, across all three entry points and `flush_pending`. The previous version of this row was false: it was backed by a test that stubbed the POST, and `t()` never POSTs. |
| WIRE-5 | **implemented** | live | `api_url:` is injectable and `LANGSYS_API_URL` is honoured; the live suite runs entirely through it. |
| CONF-1 | **partial** | live | The rules that carry risk (GATE-1/3/4, WIRE-3, CID-1) are asserted against the live server or the shared fixture. The older `client_spec`/`html_spec` request-body assertions remain — **known residue, routed to the program's E2E wave**, where live-assertion infrastructure is the focus. Deliberately not converted here. |
| CONF-2 | **implemented** | — | Every row carries a graded tier, and rows resting on mocked transport say so rather than claiming `live`. |
| CONF-3 | not implemented | none | Mutation proofs are run and reported every wave, but they are **not a committed, re-runnable suite**, so the counts rest on a session's word — the self-reported claim this file exists to prevent, one level up. Deliberately left open pending the fleet-shared mutation-manifest harness; a lane-local one would be the fourth reinvention. |

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

## Provenance

Every citation in this file is re-derivable. The commands, not the values, are the record:

```
# Spec v8 blob this file rows against
git -C ../langsys2 ls-tree origin/feature/838_write_key_gating docs/sdk-spec.mdx
#   -> b657b490f07615b889081c0ac5244ec4bd73bf81   (tip 483f98fb)

# Rule count in that blob
git -C ../langsys2 cat-file blob b657b490 | grep -cE '^### [A-Z]+-[0-9]+ '
#   -> 79

# Shared canonicalization fixture (19 cases), vendored at spec/fixtures/
git -C ../langsys-js-typescript rev-parse 6596faf:tests/fixtures/canonicalization-reference.json
#   -> e4c1f185974fbf2ebda6154f36b8ed7416f1d7fa
git hash-object spec/fixtures/canonicalization-reference.json     # must match

# Shared custom_id fixture (13 rows), vendored at spec/fixtures/
git -C ../langsys-php-sdk rev-parse 8862841:tests/fixtures/custom-id-reference.json
#   -> 60dc9b33ecfd5fa3256fca7d36063ceb8ef1a00a
git hash-object spec/fixtures/custom-id-reference.json            # must match

# TOK-3's twenty-seven, order included, against the PHP source
sed -n '26,60p' ../langsys-php-sdk/src/Html/HtmlParser.php | grep -oE "'[a-z-]+'" | tr -d "'"
```

Both fixture blobs are asserted by the suite, so a vendored copy that drifts fails the
build rather than the reader.

**On `rbs -I sig validate`, and what it does not prove.** It checks the signatures are
internally well-formed; it does not check them against the implementation. Until this lane
`sig/langsys.rbs` declared none of `Html`, `Interpolate` or `Cldr`, so citing a green
`rbs` run as evidence about a tokenizer change was citing a check that could not have
failed — the same vacuous-guard shape this repo has already recorded twice. The three
modules are now declared, which makes the run meaningful for what it covers; a green
`rbs` still means "these signatures are coherent", never "the code matches them".

## On TOK-1, and why the previous pass was accidental

`<script>` and `<style>` produced no tokens before this lane, and the fixture rows for both
said *agree*. That was not an exclusion. Nokogiri models their children as `CDATA` nodes,
the walker tested `child.text?`, and `text?` is false for CDATA — so the two elements were
skipped by a property of libxml2's node modelling, with no exclusion list anywhere in the
content-block path. Swap the parser, or hand it a document where those children parse as
text, and both start leaking with nothing in the code having changed.

`<noscript>` is the same path without the accident: libxml2 parses its children as elements,
so `Enable JavaScript` was tokenized and registered. That is the divergence the fixture row
records, and it is the one that proves the pass on the other two was luck.

The exclusion is now by element name, and the test asserts the predicate directly rather
than only the outcome.

**Two CODE defects predate this lane. No row was re-graded, and an earlier draft of this
paragraph said otherwise — there were no TOK, MARK or SRV rows in this file before this
lane, because v7 had 67 rules and no TOK family at all.** What was wrong was the
implementation, not the record of it.

`script` and `style` were passing TOK-1's intent by accident of libxml2's CDATA modelling,
with no exclusion anywhere in the content-block path — a pass that would have vanished the
moment the parser changed. And the tokenizer's whitespace class was `\s`, ASCII-only in
Ruby, so every `U+00A0` and `U+2028`/`U+2029` in customer content minted an id no other SDK
could reproduce. Four of the nineteen shared fixture rows measured divergent on first run;
all four matched `langsys-php` exactly, which is what the fixture's per-lane columns are for.

**A fourth token path was missed entirely and found by review**, not by me: `translate_meta`
handed `meta["content"]` to the translator raw. It is worth recording why my search could not
see it — I grepped for the whitespace handling that was *wrong* (`\s`, `strip`, `split`), and
this path did none of them. TOK-2 says find every site that turns a text node into a token;
the sites that do nothing at all are invisible to a search shaped like that one.

## Measured, not changed: `svg`, `math`, and the two paths

TOK-1 does not name `<svg>` or `<math>`. This SDK has two tokenizing paths and they
disagree about them:

| element | content-block path (feeds `registration.rb`) | page path (`translate_page`) |
|---|---|---|
| `script` | clean (now by exclusion, previously by CDATA accident) | clean |
| `style` | clean (now by exclusion, previously by CDATA accident) | clean |
| `noscript` | **leaked** before this lane; now clean | clean |
| `template` | **leaked** before this lane; now clean | clean |
| `svg` | **leaks** `Label` from `<svg><text>Label</text></svg>` | **leaks when nested** — see below |
| `math` | **leaks** `Label` from `<math><mi>Label</mi></math>` | **leaks when nested** — see below |

**Correction: "page path: clean" was true only at the TOP LEVEL, and an earlier version of
this table said it without that qualifier.** `SKIP_ELEMENTS` guards the element walk, but a
leaf block's inner HTML is handed to `extract_phrases`, which has its own exclusion list —
and `svg`/`math` are deliberately not on it. Measured:
`<p>Hello <b>there</b> <svg><text>Label</text></svg></p>` queues the block
`["Hello", "there", "Label"]` on the page path, `math` likewise. So the two paths agree on
nested SVG (both leak) and disagree only on a top-level one. The fleet decision below was
being deferred on a measurement that understated it.

`Page::SKIP_ELEMENTS` drops top-level `svg` and `math`; neither tokenizing path drops a
nested one. The four TOK-1 names are now aligned across both paths. **`svg` and `math` are
left exactly as they are, deliberately** — no rule names them, and aligning would change the
id of every block containing inline SVG text. Which way to align is a fleet decision, not
this lane's. Reported rather than settled, now on a correct measurement.

## Measured, not adopted: the `U+FEFF` delta

`[[:space:]]` is Unicode-aware in Ruby and covers `U+00A0`, `U+2028`, `U+2029` and `U+3000`.
JavaScript's `\s` covers all of those **and** `U+FEFF`, which `[[:space:]]` does not.

No rule names `U+FEFF` and no fixture row exercises it, so adopting it here would be one
lane inventing a contract detail binding four SDKs. Measured and reported instead. Neither
class matches `U+200B`, so the two agree there.

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

Counts are **computed from the rules table above, not asserted alongside it**, and
`spec/conformance_doc_spec.rb` fails the build when the two disagree. Wave 2 shipped a
hand-maintained summary that reconciled with nothing in its own table — it miscounted,
graded rules as implemented that the table marked otherwise, and had no bucket for two of
the table's statuses. A tally of 60-odd rows drifts on the first edit; the only version
worth reading is one that cannot.

| Status | Count |
|---|---|
| implemented | 45 |
| provisional | 2 |
| partial | 1 |
| not implemented | 3 |
| n/a — profile | 26 |
| n/a — architecture | 2 |
| **total** | **79** |

`provisional` is CAT-1 and CAT-2 — implemented, but resting on mocked transport only, which
CONF-2 does not count as proof. `not implemented` is GATE-7 (no coverage-property test that
every detection path feeds exactly one lane), CONF-3 (mutation proofs are run and reported
each wave but are not a committed, re-runnable suite) and SRV-4 (no client hand-off exists;
see its row). `n/a — architecture` is GATE-6 and SRV-5, each on a stated mechanism.

**The two kinds of `n/a` are kept apart deliberately.** `n/a — profile` means the rule
addresses a different kind of SDK and nothing here could satisfy it; it is stable, and goes
stale only if that rule's Profiles line moves. `n/a — architecture` means the rule *applies*
to this profile but has nothing to bind to in this implementation — GATE-6 is `Profiles: all`
and is unfalsifiable here only because this SDK has no report lane at all. That is a fact
about the SDK, not the rule, so it can rot under you with nothing in the spec changing.
Collapsing the two labels hides exactly the row that rots silently.

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
