# frozen_string_literal: true

module Langsys
  module Html
    # A keep-together phrase host (MARK-2) registers its whole run as ONE phrase, with its inline
    # markup encoded as {m<i>o}/{m<i>c} tokens: <p>Based on {n} <strong>reviews</strong></p> is
    # "Based on {n} {m0o}reviews{m0c}". The wire form is the JS core's <Phrase> key, so an entry
    # registered by either SDK is readable by the other, and the token names are ICU argument
    # names, so a token inside a plural branch parses like any other argument.
    #
    # Slots hold an element's tag and attributes only (a shallow clone); the rendered text
    # decides where each one goes, so a translation that reorders the markup is honoured.
    # Opaque elements (TOK-1's exclusions, translate="no", and a nested marked host, MARK-4)
    # are kept whole as a deep clone behind an empty token pair and contribute no words.
    module Markup
      OPEN_START = "\u{E000}"
      OPEN_END = "\u{E001}"
      CLOSE_START = "\u{E002}"
      CLOSE_END = "\u{E003}"
      SENTINEL = /\u{E000}(\d+)\u{E001}|\u{E002}(\d+)\u{E003}/
      TOKEN = /\{m\d+[oc]\}/

      module_function

      # [phrase, slots]. Slot numbering is one depth-first pre-order counter over the phrase.
      def encode(element)
        slots = []
        text = encode_children(element, slots)
        [Html.canonical_token(text), slots]
      end

      # Interpolation params that turn each token into a sentinel the rebuild can find.
      def token_params(slot_count)
        slot_count.times.each_with_object({}) do |i, params|
          params["m#{i}o"] = "#{OPEN_START}#{i}#{OPEN_END}"
          params["m#{i}c"] = "#{CLOSE_START}#{i}#{CLOSE_END}"
        end
      end

      # Replace +element+'s children with +text+ rebuilt around +slots+. When the stream is
      # unusable (a dropped, crossed or unknown token) the markup is lost and the words kept.
      def render_into(element, text, slots)
        text = text.gsub(TOKEN, "") if text.match?(TOKEN)
        nodes = rebuild(text, slots, element.document) || [element.document.create_text_node(strip_sentinels(text))]
        element.children.each(&:unlink)
        nodes.each { |node| element.add_child(node) }
        element
      end

      def strip_sentinels(text)
        text.gsub(SENTINEL, "").gsub(/[\u{E000}-\u{E003}]/, "")
      end

      def opaque?(element)
        Html.excluded_from_tokenizing?(element.name) || Html.translation_excluded?(element) ||
          Html.marked_host?(element)
      end

      def encode_children(node, slots)
        node.children.each_with_object(+"") do |child, out|
          if child.text?
            out << child.content
          elsif child.element?
            index = slots.length
            if opaque?(child)
              slots << child.dup(1)
              out << "{m#{index}o}{m#{index}c}"
            else
              # dup(0) copies no attributes under libxml2, so clone deep and empty it.
              slots << child.dup(1).tap { |shallow| shallow.children.each(&:unlink) }
              out << "{m#{index}o}" << encode_children(child, slots) << "{m#{index}c}"
            end
          end
        end
      end

      def rebuild(text, slots, doc)
        top = []
        stack = []
        offset = 0
        text.to_enum(:scan, SENTINEL).each do
          match = Regexp.last_match
          append(doc.create_text_node(text[offset...match.begin(0)]), top, stack) if match.begin(0) > offset
          offset = match.end(0)
          open = !match[1].nil?
          index = (open ? match[1] : match[2]).to_i
          return nil if slots[index].nil?

          if open
            node = slots[index].dup(1)
            append(node, top, stack)
            stack << [index, node]
          elsif stack.empty? || stack.pop[0] != index
            return nil
          end
        end
        append(doc.create_text_node(text[offset..]), top, stack) if offset < text.length
        stack.empty? ? top : nil
      end

      def append(node, top, stack)
        stack.empty? ? top << node : stack.last[1].add_child(node)
      end
    end
  end
end
