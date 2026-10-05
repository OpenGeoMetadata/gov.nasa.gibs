require 'cgi/escape'

# Turns a Worldview layer description, written in Markdown with a little HTML, into paragraphs of plain text: one per
# paragraph, heading or list item. Links keep their text, and superscript and subscript digits become Unicode ones,
# so that "km<sup>2</sup>" reads "km²" and "NO<sub>2</sub>" reads "NO₂".
module Description
  SUPERSCRIPTS = '0123456789-+'.chars.zip('⁰¹²³⁴⁵⁶⁷⁸⁹⁻⁺'.chars).to_h.freeze
  SUBSCRIPTS = '0123456789'.chars.zip('₀₁₂₃₄₅₆₇₈₉'.chars).to_h.freeze

  # Named entities beyond the handful CGI decodes. Worldview's descriptions use &mu; and &copy;; the rest are the
  # likeliest to turn up next.
  ENTITIES = {
    'nbsp' => ' ', 'copy' => '©', 'reg' => '®', 'deg' => '°', 'mu' => 'μ', 'micro' => 'µ', 'plusmn' => '±',
    'times' => '×', 'le' => '≤', 'ge' => '≥', 'ndash' => '–', 'mdash' => '—', 'lsquo' => '‘', 'rsquo' => '’',
    'ldquo' => '“', 'rdquo' => '”', 'sup2' => '²', 'sup3' => '³'
  }.freeze

  HEADING = /\A#+\s*/
  LIST_ITEM = /\A\s*(?:[-*+]|\d+\.)\s+/
  RULE = /\A\s*(?:-{3,}|\*{3,}|_{3,})\s*\z/

  def self.paragraphs(markdown)
    blocks = markdown.to_s.gsub("\r\n", "\n").gsub(%r{<br\s*/?>}i, "\n\n").split(/\n\s*\n/)
    blocks.flat_map { |block| block_paragraphs(block) }.map { |text| inline(text) }.reject(&:empty?)
  end

  # A block is a list whose items are a paragraph each, or a paragraph wrapped over several lines, with any heading
  # in it a paragraph of its own
  def self.block_paragraphs(block)
    return [] if block.match?(RULE)

    lines = block.lines.map(&:strip).reject(&:empty?)
    return lines.map { |line| line.sub(LIST_ITEM, '') } if lines.any? && lines.all? { |line| line.match?(LIST_ITEM) }

    lines.slice_when { |line, following| line.match?(HEADING) || following.match?(HEADING) }
         .map { |group| group.map { |line| line.sub(HEADING, '') }.join(' ') }
  end

  def self.inline(text)
    text = text.gsub(/!\[[^\]]*\]\([^)]*\)/, '')                     # images
               .gsub(/\[([^\]]+)\]\([^)]*\)/, '\1')                  # links keep their text
               .gsub(/<(https?:[^>\s]+)>/, '\1')                     # autolinks
               .gsub(%r{<sup>(.*?)</sup>}i) { script(Regexp.last_match(1), SUPERSCRIPTS) }
               .gsub(%r{<sub>(.*?)</sub>}i) { script(Regexp.last_match(1), SUBSCRIPTS) }
               .gsub(/<[^>]+>/, '')                                  # any other tag
               .gsub(/\*\*(.+?)\*\*/, '\1')                           # bold
               .gsub(/(?<!\w)__(?=\S)(.+?)(?<=\S)__(?!\w)/, '\1')
               .gsub(/(?<![\w*])\*(?=\S)([^*]+?)(?<=\S)\*(?![\w*])/, '\1') # italics
               .gsub(/(?<![\w])_(?=\S)([^_]+?)(?<=\S)_(?![\w])/, '\1')
               .delete('`')
               .gsub(/\\([\\`*_{}\[\]()#+\-.!])/, '\1')               # escapes
    text = text.gsub(/&([a-z]+\d?);/) { ENTITIES.fetch(Regexp.last_match(1), Regexp.last_match(0)) }
    CGI.unescapeHTML(text).gsub(/\s+/, ' ').strip
  end

  # Characters with a Unicode superscript or subscript form become it; anything else stays as written
  def self.script(text, forms)
    text.chars.all? { |char| forms.key?(char) } ? text.chars.map { |char| forms[char] }.join : text
  end
end
