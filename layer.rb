require 'cgi/escape'
require 'date'
require_relative 'capabilities'
require_relative 'extent'

# One GIBS layer, with what each source says about it: its entries in the capabilities of each projection, GIBS's
# layer metadata, Worldview's configuration, the CMR collections it's made from, and the start of its time domain
# where the capabilities cut it short.
class Layer
  ID_PREFIX = 'nasa-gibs-'.freeze

  # Layers that help read other layers rather than show anything themselves: orbit tracks, coastlines, borders,
  # place labels, land masks, graticules and no-data masks. Some of the reference layers are derived from
  # OpenStreetMap, under the ODbL.
  UTILITY_MEASUREMENTS = ['Orbital Track', 'Reference Map', 'Latitude-Longitude Lines', 'Areas of No Data'].freeze

  VECTOR_FORMAT = 'application/vnd.mapbox-vector-tile'.freeze

  # [west, south, east, north]. Every layer's capabilities claim this, regional or not.
  GLOBE = [-180.0, -90.0, 180.0, 90.0].freeze

  # A union of extents covering more than this share of the globe counts as the globe: SMAP's, for instance, stop at
  # 85 degrees, which no search would tell apart
  GLOBAL_SHARE = 0.9

  # GIBS calls a few dozen layers ongoing that have had no new imagery for a year or more. Past this many days
  # without any, a layer is treated as ended; yearly layers are allowed two of their periods.
  STALE_AFTER = 400
  STALE_AFTER_YEARLY = 800

  # Platform types whose collections hold observations of the Earth from above, as opposed to models and analyses
  REMOTE_SENSING_PLATFORMS = ['Earth Observation Satellites', 'Space Stations/Crewed Spacecraft', 'Propeller', 'Jet',
                              'Uncrewed Vehicles'].freeze

  # e.g. nasa-gibs-modis_terra_correctedreflectance_truecolor. Identifiers never differ only in case; the dots a
  # few have become hyphens.
  def self.record_id(identifier)
    "#{ID_PREFIX}#{identifier.downcase.gsub(/[^a-z0-9_-]/, '-')}"
  end

  attr_reader :identifier, :entries, :metadata, :domain_start, :today

  # @param entries [Hash{String => Capabilities::Entry}] by projection
  # @param today [Date] what "ongoing" is measured from
  def initialize(identifier, entries, metadata:, worldview:, collections:, domain_start: nil, today: Date.today)
    @identifier = identifier
    @today = today
    @entries = entries
    @metadata = metadata
    @worldview = worldview
    @collections = collections
    @domain_start = domain_start
  end

  def id
    self.class.record_id(identifier)
  end

  # The entry its dates and format are read from
  def entry
    Capabilities.primary(entries)
  end

  # Why the layer gets no record, or nil if it gets one
  # @return [Symbol, nil] :undocumented when GIBS has no layer metadata for it, :utility, or :broken when its tile
  #   template asks for a date its capabilities don't offer, which GIBS answers with a 404 for every tile
  def skip_reason
    return :undocumented unless metadata
    return :utility if UTILITY_MEASUREMENTS.include?(measurement)
    return :broken if entry.time.nil? && entry.tile_templates.any? { |template| template.include?('{Time}') }

    nil
  end

  def measurement
    metadata&.[]('measurement')
  end

  def period
    metadata&.[]('layerPeriod')
  end

  # Whether GIBS still adds imagery, as its layer metadata says, unless the layer has had none for so long that it
  # plainly doesn't
  def ongoing?
    return false unless metadata&.[]('ongoing') == true && last_day

    Date.parse(last_day) >= today - (period == 'Yearly' ? STALE_AFTER_YEARLY : STALE_AFTER)
  end

  def vector?
    entry.format == VECTOR_FORMAT
  end

  def web_mercator
    entries[Capabilities::WEB_MERCATOR]
  end

  def polar_only?
    (entries.keys - Capabilities::POLAR).empty?
  end

  # Worldview's configuration for the layer, or nil if Worldview doesn't show it
  def worldview_config
    @worldview[identifier]
  end

  # Worldview's title and subtitle where it overrides GIBS's, otherwise GIBS's layer metadata. The capabilities'
  # titles are a last resort: a dozen pairs of layers share one, e.g. OSCAR's meridional currents are titled "Zonal".
  def title
    config = worldview_config || {}
    base = config['title'] || metadata&.[]('title') || entry.title
    subtitle = CGI.unescapeHTML((config['subtitle'] || metadata&.[]('subtitle')).to_s).strip
    subtitle.empty? ? base : "#{base}, #{subtitle}"
  end

  # Worldview's description, as paragraphs
  def description
    @worldview.description(identifier)
  end

  def disciplines
    @worldview.disciplines(identifier, measurement: measurement)
  end

  # The CMR collections the layer is made from that CMR still has, each once per product and version: the standard
  # products where there are any, since the imagery is archived from those, otherwise the near-real-time ones
  # @return [Array<Hash>] GIBS's entries for the collections, with CMR's metadata as 'umm'
  def sources
    @sources ||= begin
      linked = (metadata&.[]('conceptIds') || []).filter_map do |concept|
        umm = @collections[concept['value']]
        concept.merge('umm' => umm) if umm
      end
      standard = linked.select { |concept| concept['type'] == 'STD' }
      (standard.empty? ? linked : standard).uniq { |concept| [concept['shortName'], concept['version']] }
    end
  end

  def platforms
    sources.flat_map { |source| source.dig('umm', 'Platforms') || [] }
  end

  def remote_sensing?
    sources.empty? || platforms.any? { |platform| REMOTE_SENSING_PLATFORMS.include?(platform['Type']) }
  end

  # The first day the layer has imagery for, as YYYY-MM-DD; nil for a layer without dates
  def first_day
    [entry.time&.first_day, domain_start].compact.min
  end

  def last_day
    entry.time&.last_day
  end

  # Whether its only date is a single day
  def single_day?
    entry.time && first_day == last_day
  end

  def years
    first_day && (first_day[0, 4].to_i..last_day[0, 4].to_i).to_a
  end

  # [west, south, east, north]: the union of its source collections' rectangles and polygons, the globe when that
  # covers nearly all of it or there's nothing to go on, and for a layer published only in a polar projection, that
  # projection's bounding box
  def bounds
    @bounds ||= begin
      boxes = sources.flat_map { |source| boxes(source['umm']) }
      if boxes.any?
        union(boxes)
      elsif polar_only?
        entry.bbox || GLOBE
      else
        GLOBE
      end
    end
  end

  def global?
    bounds == GLOBE
  end

  private

  def boxes(umm)
    geometry = umm.dig('SpatialExtent', 'HorizontalSpatialDomain', 'Geometry') || {}
    rectangles = (geometry['BoundingRectangles'] || []).map do |rectangle|
      %w[West South East North].map { |side| rectangle["#{side}BoundingCoordinate"].to_f }
    end
    polygons = (geometry['GPolygons'] || []).filter_map do |polygon|
      points = polygon.dig('Boundary', 'Points') || []
      next if points.empty?

      longitudes = points.map { |point| point['Longitude'].to_f }
      latitudes = points.map { |point| point['Latitude'].to_f }
      [longitudes.min, latitudes.min, longitudes.max, latitudes.max]
    end
    (rectangles + polygons).select { |_west, south, _east, north| south <= north }
  end

  def union(boxes)
    extent = Extent.new
    boxes.each { |west, south, east, north| extent.add(west, east, north, south) }
    west, east = extent.longitudes
    box = [west, extent.south, east, extent.north]
    width = east >= west ? east - west : east - west + 360
    share = (width / 360.0) * ((extent.north - extent.south) / 180.0)
    share > GLOBAL_SHARE ? GLOBE : box
  end
end
