# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Initial base SDK: `Langsys::Client` with catalog fetch + two-tier cache, phrase resolution
  (untranslated → source phrase), parameter interpolation with locale-aware CLDR formatting
  and an ICU MessageFormat subset (`plural` / `select` / `selectordinal` / `number` / `date`
  / `time`). A missing or `nil` ICU argument recovers the same way as
  langsys-js-typescript 0.6.4 and langsys-php 1.3.1, so a phrase Langsys promoted to
  `{name_gender, select, …}` reads as a sentence when the app passes no gender: `select`
  takes its `other` branch, `plural` takes `other` with `#` shown as `{name}`, and any other
  slot stays visible as `{name}`.
- Phrase discovery queue with write-gated `flush_pending`; explicit `register_phrases`,
  `register_content_block`, and `sync`; PHP-compatible content-block `custom_id` hashing.
- Reference data: `countries`, `dial_codes`, `currencies`, `locales`, `locales_flat`,
  `locales_data`, and localized name lookups.
- Locale helpers: canonicalization, `Accept-Language` parsing, and `detect_preferred_locale`.
- Cache backends (`Memory`, `File`, `Null`) and a `Signal` locale-source binding point for
  framework wrappers.
- Server-side HTML translation (optional, needs Nokogiri): `translate_content_block` and
  `translate_page` (head + body walk, simple-phrase vs content-block classification,
  `data-langsys-category` / `data-langsys-contentblock` / `translate="no"` / selector
  categories), with a configurable translatable-attribute list.
