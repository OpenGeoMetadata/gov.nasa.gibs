require 'rexml/document'
require_relative 'http_client'
require_relative 'snapshot'

# The layers GIBS offers, from the WMTS capabilities document of each projection's "best available" endpoint.
# "Best" merges each layer's near-real-time and standard versions under one identifier; the "all" endpoints would
# add every versioned variant as a layer of its own.
class Capabilities
  PROJECTIONS = %w[epsg4326 epsg3857 epsg3413 epsg3031].freeze
  WEB_MERCATOR = 'epsg3857'.freeze
  POLAR = %w[epsg3413 epsg3031].freeze

  # GIBS lists only the latest 100 periods of a layer's time dimension; a layer listing that many may have more
  TRUNCATED_AT = 100

  # What a layer is in one projection: its title, extent in degrees, image format, tile grid, tile URL templates,
  # the templates for its DescribeDomains documents, and its time dimension if it has one
  Entry = Struct.new(:title, :bbox, :format, :tile_matrix_set, :tile_templates, :domain_templates, :time,
                     keyword_init: true)

  # A time dimension: its default value, and the values GIBS lists, as ISO 8601 instants or start/end/period
  # intervals
  Dimension = Struct.new(:default, :values, keyword_init: true) do
    # The first and last days the values cover, as YYYY-MM-DD
    def first_day
      values.map { |value| value.split('/').first[0, 10] }.min
    end

    def last_day
      values.map { |value| (value.split('/')[1] || value)[0, 10] }.max
    end

    def truncated?
      values.size >= TRUNCATED_AT
    end
  end

  class Error < StandardError; end

  # The entry a layer's dates and format are read from: Geographic, else Web Mercator, else a polar projection
  def self.primary(entries)
    entries['epsg4326'] || entries[WEB_MERCATOR] || entries.values.first
  end

  def self.url(projection)
    "https://gibs.earthdata.nasa.gov/wmts/#{projection}/best/1.0.0/WMTSCapabilities.xml"
  end

  def self.file(projection)
    "capabilities-#{projection}.xml"
  end

  def self.fetch(http: HttpClient.new, log: $stdout)
    documents = PROJECTIONS.to_h do |projection|
      response = http.get(url(projection))
      raise Error, "#{url(projection)} answered #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      [projection, response.body.to_s.dup.force_encoding(Encoding::UTF_8)]
    end
    new(documents).tap do |capabilities|
      capabilities.counts.each { |projection, count| log.puts "Capabilities #{projection}: #{count} layers" }
    end
  end

  def self.load(dir)
    new(PROJECTIONS.to_h { |projection| [projection, Snapshot.read_text(dir, file(projection))] })
  end

  attr_reader :documents

  # @param documents [Hash{String => String}] each projection's capabilities XML
  def initialize(documents)
    @documents = documents
    @layers = Hash.new { |hash, id| hash[id] = {} }
    documents.each { |projection, xml| parse(projection, xml) }
    @layers.default_proc = nil
    empty = PROJECTIONS.reject { |projection| counts[projection].to_i.positive? }
    raise Error, "The capabilities for #{empty.join(', ')} list no layers" if empty.any?
  end

  def save(dir)
    documents.each { |projection, xml| Snapshot.write_text(dir, self.class.file(projection), xml) }
  end

  # @return [Hash{String => Hash{String => Entry}}] each layer's entries, by identifier and then projection
  def layers
    @layers
  end

  def counts
    PROJECTIONS.to_h { |projection| [projection, @layers.count { |_id, entries| entries.key?(projection) }] }
  end

  private

  def parse(projection, xml)
    root = REXML::Document.new(xml).root
    unless root&.name == 'Capabilities'
      raise Error, "The #{projection} capabilities aren't a WMTS capabilities document"
    end

    root.elements['Contents']&.each_element('Layer') do |layer|
      id = text(layer, 'ows:Identifier')
      @layers[id][projection] = entry(layer) if id
    end
  end

  def entry(layer)
    resources = layer.get_elements('ResourceURL')
    Entry.new(
      title: text(layer, 'ows:Title'),
      bbox: bbox(layer.elements['ows:WGS84BoundingBox']),
      format: text(layer, 'Format'),
      tile_matrix_set: text(layer, 'TileMatrixSetLink/TileMatrixSet'),
      tile_templates: templates(resources, 'tile'),
      domain_templates: templates(resources, 'Domains'),
      time: time(layer)
    )
  end

  def templates(resources, type)
    resources.select { |resource| resource.attributes['resourceType'] == type }
             .map { |resource| resource.attributes['template'] }
  end

  # [west, south, east, north]; OWS writes each corner as "longitude latitude" whatever the projection
  def bbox(element)
    return nil unless element

    %w[ows:LowerCorner ows:UpperCorner].flat_map { |corner| text(element, corner).to_s.split.map(&:to_f) }
  end

  def time(layer)
    dimension = layer.get_elements('Dimension').find { |element| text(element, 'ows:Identifier')&.casecmp?('time') }
    return nil unless dimension

    values = dimension.get_elements('Value').map { |value| value.text.to_s.strip }.reject(&:empty?)
    values.empty? ? nil : Dimension.new(default: text(dimension, 'Default'), values: values)
  end

  def text(element, path)
    element.elements[path]&.text&.strip
  end
end
