# langsys (Ruby)

The framework-agnostic **Ruby base SDK** for the [Langsys](https://langsys.dev) Translation
Manager — realtime, continuous translations. The phrase in your code is the lookup key **and**
the base-language default: no keys file, no extraction step. Untranslated phrases render as
the source phrase.

It's the Ruby sibling of the [TypeScript](https://github.com/langsys/langsys-js-typescript),
[PHP](https://github.com/langsys/langsys-php), and [Python](https://github.com/langsys/langsys-python)
base SDKs — independent and idiomatic, but speaking the same nova HTTP API. Framework wrappers
(Rails, …) build thinly on top of it.

## Install

```ruby
# Gemfile
gem "langsys"
```

Then `bundle install`. Requires Ruby 3.0+. The only runtime dependency is
[`twitter_cldr`](https://github.com/twitter/twitter-cldr-rb) (pure Ruby — no native
extensions), used for CLDR plural rules and locale-aware number/date formatting.
[Server-side HTML translation](#server-side-html-translation) additionally needs
[`nokogiri`](https://nokogiri.org) — add `gem "nokogiri"` only if you use it.

## Quick start

```ruby
require "langsys"

client = Langsys::Client.new(api_key: "…", project_id: "…")  # or LANGSYS_API_KEY / LANGSYS_PROJECT_ID
client.set_locale("es-ES")

client.t("Save", category: "UI")
client.t("Hello, {name}!", category: "Greetings", params: { name: "Sarah" })
```

> The signature is `t(phrase, category:, params:, locale:)` — the **phrase comes first** and is
> both the lookup key and the English default. `t` is an alias of `translate`.

The category is part of the key, so the same word can be translated differently per context:

```ruby
client.t("Home", category: "Main Menu")     # the nav item
client.t("Home", category: "Home repairs")  # the building
```

## Parameters, formatting & ICU

Params accept strings, numbers, `Date`/`Time`/`DateTime`, and booleans. Numbers and dates are
CLDR-formatted in the loaded locale (`1234567` → `1,234,567` in `en`, `1.234.567` in `de`);
pass a **string** to opt out of grouping — for ids and codes. Booleans render as
`"true"`/`"false"`. An unknown or `nil` param is left visible (`{name}`) so missing data is
obvious.

ICU MessageFormat is supported for pluralization and selection — `plural`, `selectordinal`,
`select`, and `{n, number|date|time}`, with `#` and `offset:` — backed by real CLDR plural
rules (so Polish gets `one/few/many/other`, Arabic its six categories, and so on):

```ruby
client.t(
  "You have {count, plural, one {# new message} other {# new messages}}.",
  category: "Inbox",
  params: { count: 3 }
)
# => "You have 3 new messages."
```

Malformed ICU degrades to simple `{name}` interpolation instead of raising, so a bad string
never blanks a page.

## Discovering & registering phrases

Phrases seen at runtime that aren't in the catalog are **queued for discovery**. With a
**write** key you can register them; a **read** key never writes.

```ruby
client.t("A brand new phrase", category: "UI")   # queued if missing
client.has_pending?                               # => true
client.flush_pending                              # registers the queue (write key) or drops it (read key)

client.register_phrases(["Save", { phrase: "Delete", category: "UI" }])
client.register_content_block(html, ["Welcome", "Browse the catalog"], category: "Home")
client.sync(["Save", "Cancel"])                   # register only what's missing, then refetch
```

A read key calling a registration method directly raises `Langsys::AuthorizationError`.

## Server-side HTML translation

Translate rendered markup directly — the SDK walks the DOM, translates text and a fixed set of
translatable attributes (`placeholder`, `alt`, `title`, `aria-label`, …) and button/submit
values, and skips `translate="no"` / `data-notrans` subtrees. This needs
[Nokogiri](https://nokogiri.org) — add `gem "nokogiri"` (it's an optional dependency; the rest
of the SDK works without it).

```ruby
# One block, localized as a single unit:
client.translate_content_block("<h3>Welcome</h3><p>Browse the catalog</p>", category: "Home")

# A whole page (head + body):
client.translate_page(html)
```

`translate_page` walks the `<head>` (title; `description`/`keywords`/`author` metas; OpenGraph
and Twitter cards; `<html lang>`; `og:locale`) and the `<body>`, classifying each leaf block as
a **simple phrase** (its whole text is one phrase) or a **content block** (markup-bearing /
multi-phrase). It honors:

- `data-langsys-category="News"` — set the category for an element and its subtree,
- `data-langsys-contentblock` — force an element to be treated as one content block,
- `translate="no"` / `data-notrans` — leave a subtree verbatim,
- an optional `selector_categories:` map — assign categories by CSS selector:

```ruby
client.translate_page(html, category: "Marketing", selector_categories: {
  "#hero"   => "Home",
  ".legal"  => { category: "Legal", override: true } # override inherited/element categories
})
```

Unknown blocks are returned unchanged and queued for registration (see `flush_pending`). The
translatable-attribute list is configurable: `get_translatable_attributes`,
`set_translatable_attributes`, `add_translatable_attributes`, `reset_translatable_attributes`.

## Reference data

Fetched live from nova (nothing bundled) and cached per display locale; names come back
already localized.

```ruby
client.countries("es-ES")        # => [#<Langsys::Country code="US" label="Estados Unidos">, …]
client.currencies                # loaded locale
client.currency_name("USD")
client.dial_codes
client.locales                   # grouped by language
client.locales_flat
client.locale_name("es-ES")      # localized display name
client.detect_preferred_locale(accept_language_header, ["en-US", "es-ES"])
```

## Locale resolution & bringing your own source

The client owns a locale you drive with `set_locale`, **or** you hand it any object responding
to `get` / `subscribe` (a request-scoped store, a settings signal). The client only **reads**
and **subscribes** — it never writes the source — which is exactly the binding point a
framework wrapper uses to stay request-safe with a single shared client. `Langsys::Signal` is
the built-in implementation:

```ruby
store  = Langsys::Signal.new("en-US")
client = Langsys::Client.new(api_key: "…", project_id: "…", locale_source: store)
store.set("es-ES")               # drives the client's locale (calling set_locale here raises)
```

`detect_preferred_locale` parses an `Accept-Language` header and matches it against a supported
list in two tiers — exact canonical match, then primary-language — returning `nil` when nothing
matches so you can fall back to a default.

## Caching

Catalogs and reference data are cached in two tiers: a fast in-process hash plus a pluggable
backend. The default persistent backend is `Langsys::Cache::File` (JSON files under the system
temp dir); `Langsys::Cache::Memory` and `Langsys::Cache::Null` are also provided, and any
object responding to `get` / `set` / `delete` / `clear` works.

```ruby
Langsys::Client.new(api_key: "…", project_id: "…",
                    cache: Langsys::Cache::Memory.new, cache_ttl: 600)

client.clear_cache        # drop cached catalogs
client.refresh            # drop catalogs *and* reference data
```

## Error handling

Every failure is a `Langsys::Error`. API responses map to typed subclasses so you can rescue
precisely; `Net::HTTP` types never leak out.

| Class | When |
|-------|------|
| `Langsys::ConfigurationError` | missing api key / project id, bad response shape |
| `Langsys::NetworkError` | the API couldn't be reached (DNS, connect, timeout) |
| `Langsys::AuthenticationError` | 401 — key rejected |
| `Langsys::PaymentRequiredError` | 402 — usage/subscription limit |
| `Langsys::AuthorizationError` | 403 — key not allowed (e.g. read key writing) |
| `Langsys::ValidationError` | 422 — request rejected (`#errors` has details) |
| `Langsys::RateLimitError` | 429 — throttled |
| `Langsys::ApiError` | any other non-2xx (`#status_code`, `#response`, `#request_id`) |

Translation itself never raises on a missing phrase — it returns the source phrase.

## Configuration

Pass arguments to `Client.new` or set the environment variables:

| Argument | Env var | Default |
|----------|---------|---------|
| `api_key` | `LANGSYS_API_KEY` | — (required) |
| `project_id` | `LANGSYS_PROJECT_ID` | — (required) |
| `api_url` | `LANGSYS_API_URL` | `https://api.langsys.dev/api` |
| `base_locale` | `LANGSYS_BASE_LOCALE` | project's base locale |
| `cache_ttl` | `LANGSYS_CACHE_TTL` | `3600` |
| `cache` | — | `Langsys::Cache::File` |
| `timeout` | — | `30.0` (seconds) |
| `locale_source` | — | an internal `Signal` |
| `auto_flush` | — | `false` (register the queue at exit) |

## Development

```bash
bundle install
bundle exec rake spec          # unit specs (WebMock — no network)
bundle exec rake integration   # live specs against a Langsys backend (needs LANGSYS_* env)
bundle exec rubocop
bundle exec rake rbs           # validate the RBS type signatures
```

Type signatures for the public API ship in `sig/` (RBS).

Run the live specs against a backend by exporting credentials, e.g.:

```bash
LANGSYS_PROJECT_ID=… LANGSYS_API_KEY=… LANGSYS_API_URL=http://localhost:8000/api \
  bundle exec rake integration
```

## Releasing

Published to [RubyGems](https://rubygems.org) manually. Bump `Langsys::VERSION`, update
`CHANGELOG.md`, then:

```bash
gem build langsys.gemspec
gem push langsys-<version>.gem   # requires a RubyGems account with push access
```

## License

MIT
