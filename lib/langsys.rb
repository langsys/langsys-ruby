# frozen_string_literal: true

require "set"

require_relative "langsys/version"
require_relative "langsys/errors"
require_relative "langsys/signal"
require_relative "langsys/locale"
require_relative "langsys/types"
require_relative "langsys/cache"
require_relative "langsys/config"
require_relative "langsys/http"
require_relative "langsys/catalog"
require_relative "langsys/interpolate"
require_relative "langsys/registration"
require_relative "langsys/utilities"
require_relative "langsys/html/parser"
require_relative "langsys/html/page"
require_relative "langsys/client"

# Langsys — the official Ruby SDK for realtime, continuous translations.
#
#   require "langsys"
#
#   client = Langsys::Client.new(api_key: "…", project_id: "…")  # or LANGSYS_API_KEY / LANGSYS_PROJECT_ID
#   client.set_locale("es-ES")
#   client.t("Hello, {name}!", category: "Greetings", params: { name: "Sarah" })
#
# The phrase in your code is the lookup key *and* the base-language default — no keys file,
# no extraction step. Untranslated phrases render as the source phrase.
module Langsys
  module_function

  # Convenience: build a client (same arguments as +Client.new+).
  def new(**kwargs)
    Client.new(**kwargs)
  end

  # Module-level helpers mirroring the other SDKs' free functions.
  def canonicalize_locale(locale) = Locale.canonicalize_locale(locale)
  def normalize_locale(locale) = Locale.normalize_locale(locale)
  def parse_accept_language(header) = Locale.parse_accept_language(header)

  def detect_preferred_locale(accept_language = nil, supported = nil)
    Locale.detect_preferred_locale(accept_language, supported)
  end

  def interpolate(template, params, locale = "en")
    Interpolate.call(template, params, locale)
  end

  def icu?(template) = Interpolate.icu?(template)
end
