require 'date'
require 'json'
require_relative 'layer'

# Maps one GIBS layer to an OGM Aardvark record, and builds the collection record every layer is a member of.
# Conventions follow gov.usgs.htmc and gov.usgs.tnm, so that the repositories' records read alike.
class Mapper
  COLLECTION_ID = 'nasa-gibs'.freeze
  PROVIDER = 'National Aeronautics and Space Administration'.freeze
  NASA = 'United States. National Aeronautics and Space Administration'.freeze
  KEYWORD = 'Global Imagery Browse Services'.freeze

  # What GIBS asks of anyone using or citing its imagery
  ACKNOWLEDGEMENT = "We acknowledge the use of imagery provided by services from NASA's Global Imagery Browse " \
                    "Services (GIBS), part of NASA's Earth Science Data and Information System (ESDIS).".freeze

  COLLECTION_DESCRIPTION = [
    "NASA's Global Imagery Browse Services (GIBS) system provides visualizations of NASA Earth Science observations " \
    'through standardized web services. These services deliver global, full-resolution visualizations of satellite ' \
    'data to users in a highly responsive manner, enabling visual discovery of scientific phenomena, supporting ' \
    'timely decision-making for natural hazards, educating the next generation of scientists, and making imagery ' \
    'of the planet more accessible to the media and public.'
  ].freeze

  DOCS_URL = 'https://nasa-gibs.github.io/gibs-api-docs/'.freeze
  WORLDVIEW_URL = 'https://worldview.earthdata.nasa.gov/'.freeze
  WMTS_URL = 'https://gibs.earthdata.nasa.gov/wmts/epsg3857/best/1.0.0/WMTSCapabilities.xml'.freeze
  WMS_URL = 'https://gibs.earthdata.nasa.gov/wms/epsg3857/best/wms.cgi'.freeze
  # GIBS's Web Mercator WMS doesn't serve vector layers; its documentation says to ask the Geographic one for Web
  # Mercator images of them instead, which takes the same EPSG:3857 requests
  VECTOR_WMS_URL = 'https://gibs.earthdata.nasa.gov/wms/epsg4326/best/wms.cgi'.freeze

  XYZ = 'https://wiki.openstreetmap.org/wiki/Slippy_map_tilenames'.freeze
  WMTS = 'http://www.opengis.net/def/serviceType/ogc/wmts'.freeze
  WMS = 'http://www.opengis.net/def/serviceType/ogc/wms'.freeze

  # Worldview's science disciplines, as Aardvark themes
  THEMES = {
    'Atmosphere' => 'Climate', 'Biosphere' => 'Biology', 'Cryosphere' => 'Climate', 'Human Dimensions' => 'Society',
    'Land Surface' => 'Land Cover', 'Oceans' => 'Oceans', 'Spectral/Engineering' => 'Imagery',
    'Terrestrial Hydrosphere' => 'Inland Waters'
  }.freeze

  # Measurements whose layers are pictures of the Earth, made by combining bands, rather than a quantity drawn
  # through a color map
  COMPOSITES = ['Corrected Reflectance', 'Land Surface Reflectance', 'Geostationary', 'Earth at Night',
                'Blue Marble'].freeze

  SATELLITES = ['Earth Observation Satellites', 'Space Stations/Crewed Spacecraft'].freeze

  CREATIVE_COMMONS = %r{https?://creativecommons\.org/licenses/[a-z-]+/\d\.\d}

  FORMATS = { 'image/jpeg' => 'JPEG', 'image/png' => 'PNG', Layer::VECTOR_FORMAT => 'Mapbox Vector Tile' }.freeze

  # Words that stay lowercase inside a subject heading made from a GCMD keyword
  MINOR_WORDS = %w[a an and as at by for from in of on or the to with].freeze

  # How long a citation's creator can run before it's really a list of names
  MAX_CREATOR_LENGTH = 120

  MAX_SUBJECTS = 6

  # Map a GIBS layer to OGM Aardvark
  # @param distinguish [Boolean] whether another layer would get the same title, so this one's needs its identifier
  # @param modified [Date] the date for gbl_mdModified_dt; the harvester keeps the old one when nothing else changed
  def self.map(layer, distinguish: false, modified: Date.today)
    new(layer, distinguish: distinguish, modified: modified).map
  end

  # The record every layer is a member of. Its years summarize the layers', so it changes only when they do.
  def self.collection(layers, modified: Date.today)
    years = layers.filter_map(&:years).flatten.minmax
    compact(
      'id' => COLLECTION_ID,
      'dct_title_s' => 'NASA Global Imagery Browse Services (GIBS)',
      'dct_description_sm' => COLLECTION_DESCRIPTION,
      'dct_creator_sm' => [NASA],
      'dct_publisher_sm' => [NASA],
      'dct_temporal_sm' => years.compact.any? ? [years.uniq.join('-')] : nil,
      'gbl_indexYear_im' => years.compact.any? ? (years.first..years.last).to_a : nil,
      'gbl_dateRange_drsim' => years.compact.any? ? ["[#{years.first} TO #{years.last}]"] : nil,
      'schema_provider_s' => PROVIDER,
      'gbl_resourceClass_sm' => ['Collections'],
      'gbl_resourceType_sm' => ['Satellite imagery', 'Remote-sensing maps'],
      'dcat_keyword_sm' => [KEYWORD],
      'locn_geometry' => format_envelope(*Layer::GLOBE),
      'dcat_bbox' => format_envelope(*Layer::GLOBE),
      'dct_rights_sm' => [ACKNOWLEDGEMENT],
      'dct_accessRights_s' => 'Public',
      'gbl_mdModified_dt' => timestamp(modified),
      'gbl_mdVersion_s' => 'Aardvark',
      'dct_references_s' => { 'http://schema.org/url' => DOCS_URL }.to_json
    )
  end

  # Solr's ENVELOPE(west, east, north, south) syntax, from [west, south, east, north]. west > east crosses the
  # antimeridian.
  def self.format_envelope(west, south, east, north)
    "ENVELOPE(#{[west, east, north, south].map { |coordinate| format_coordinate(coordinate) }.join(', ')})"
  end

  def self.format_coordinate(value)
    format('%.6f', Float(value)).sub(/0+\z/, '').sub(/\.\z/, '')
  end

  def self.timestamp(date)
    "#{date.iso8601}T00:00:00Z"
  end

  # Drop fields with nothing to say, so records don't carry empty strings or arrays
  def self.compact(record)
    record.reject { |_key, field| field.nil? || (field.respond_to?(:empty?) && field.empty?) }
  end

  attr_reader :layer

  def initialize(layer, distinguish: false, modified: Date.today)
    @layer = layer
    @distinguish = distinguish
    @modified = modified
  end

  # Keys follow the order of gov.usgs.htmc's records, so that diffs between runs read in a familiar order
  # @return [Hash]
  def map
    self.class.compact(
      'id' => layer.id,
      'dct_title_s' => title,
      'dct_description_sm' => description,
      'dct_creator_sm' => creators,
      'dct_publisher_sm' => [NASA],
      'dct_temporal_sm' => temporal,
      'gbl_indexYear_im' => layer.years,
      'gbl_dateRange_drsim' => layer.years && ["[#{layer.years.first} TO #{layer.years.last}]"],
      'schema_provider_s' => PROVIDER,
      'dct_identifier_sm' => [layer.identifier],
      'dct_subject_sm' => subjects,
      'dcat_theme_sm' => themes,
      'dcat_keyword_sm' => keywords,
      'gbl_resourceClass_sm' => [layer.vector? ? 'Datasets' : 'Imagery'],
      'gbl_resourceType_sm' => resource_types,
      'dct_format_s' => FORMATS[layer.entry.format],
      'locn_geometry' => envelope,
      'dcat_bbox' => envelope,
      'dcat_centroid' => centroid,
      'pcdm_memberOf_sm' => [COLLECTION_ID],
      'dct_rights_sm' => rights,
      'dct_license_sm' => licenses,
      'dct_accessRights_s' => 'Public',
      'gbl_mdModified_dt' => self.class.timestamp(@modified),
      'gbl_mdVersion_s' => 'Aardvark',
      'gbl_wxsIdentifier_s' => layer.web_mercator ? layer.identifier : nil,
      'dct_references_s' => references.to_json
    )
  end

  # The title, with the layer's identifier added when another layer's would be the same
  def title
    @distinguish ? "#{layer.title} (#{layer.identifier})" : layer.title
  end

  def composite?
    COMPOSITES.include?(layer.measurement)
  end

  private

  # Worldview's description, then a paragraph on what GIBS has and what it's made from. The description's own list
  # of references goes when the layer's source collections can be named instead, with their DOIs. A layer Worldview
  # doesn't describe gets its first source collection's abstract.
  def description
    paragraphs = layer.description
    paragraphs = paragraphs.reject { |paragraph| paragraph.start_with?('References') } if layer.sources.any?
    abstract = layer.sources.first&.dig('umm', 'Abstract')
    return [summary, abstract.gsub(/\s+/, ' ').strip] if paragraphs.empty? && abstract

    paragraphs + [summary]
  end

  # e.g. "A daily visualization from NASA's Global Imagery Browse Services (GIBS), available from 2000-02-24 and
  # updated as new data arrive. Made from MODIS/Terra Calibrated Radiances 5-Min L1B Swath 1km (MOD021KM, version
  # 6.1, doi:10.5067/MODIS/MOD021KM.061)."
  def summary
    period = layer.period&.downcase
    article = period&.match?(/\A(?:[aeiou]|8|11|18)/) ? 'An' : 'A'
    sentence = "#{article} #{period ? "#{period} " : ''}visualization from NASA's Global Imagery Browse Services (GIBS)"
    sentence += ", #{coverage}" if coverage
    made_from = layer.sources.map do |source|
      title = (source.dig('umm', 'EntryTitle') || source['title']).to_s.gsub(/\s+/, ' ').strip
      details = [source['shortName'], source['version']&.then { |version| "version #{version}" },
                 doi(source)&.then { |doi| "doi:#{doi}" }]
      "#{title} (#{details.compact.join(', ')})"
    end
    made_from.any? ? "#{sentence}. Made from #{made_from.join('; ')}." : "#{sentence}."
  end

  def coverage
    return nil unless layer.first_day
    return "for #{layer.first_day}" if layer.single_day?
    return "available from #{layer.first_day} and updated as new data arrive" if layer.ongoing?

    "covering #{layer.first_day} to #{layer.last_day}"
  end

  def doi(source)
    source.dig('umm', 'DOI', 'DOI')&.strip&.sub(%r{\A(?:https?://(?:dx\.)?doi\.org/|doi:)}i, '')
  end

  # Ongoing layers say "to present" rather than give their latest date, which changes daily. A layer whose one date
  # is the first of a year, as annual products are dated, gives just the year.
  def temporal
    return nil unless layer.first_day
    if layer.single_day?
      return [layer.first_day.end_with?('-01-01') ? layer.first_day[0, 4] : layer.first_day]
    end

    ["#{layer.first_day} to #{layer.ongoing? ? 'present' : layer.last_day}"]
  end

  # The people or teams the source collections' citations credit, otherwise the data centers that originated or
  # processed them
  def creators
    citations = layer.sources.flat_map { |source| source.dig('umm', 'CollectionCitations') || [] }
                     .filter_map { |citation| citation['Creator']&.gsub(/\s+/, ' ')&.strip }
                     .reject { |creator| creator.empty? || creator.length > MAX_CREATOR_LENGTH }
    return citations.uniq.first(3) if citations.any?

    centers = layer.sources.flat_map { |source| source.dig('umm', 'DataCenters') || [] }
    %w[ORIGINATOR PROCESSOR].each do |role|
      names = centers.select { |center| (center['Roles'] || []).include?(role) }
                     .filter_map { |center| center['LongName'] || center['ShortName'] }
      return names.uniq.first(3) if names.any?
    end
    nil
  end

  # GIBS's measurement, then the source collections' GCMD science keywords at their most specific level
  def subjects
    keywords = layer.sources.flat_map { |source| source.dig('umm', 'ScienceKeywords') || [] }
                    .filter_map { |keyword| keyword['VariableLevel1'] || keyword['Term'] }
    ([layer.measurement] + keywords.map { |keyword| heading(keyword) }).compact.uniq.first(MAX_SUBJECTS)
  end

  # "SEA SURFACE TEMPERATURE" -> "Sea Surface Temperature"; short words like "UV" stay capitals
  def heading(keyword)
    keyword.split(/(\s+|\/|-)/).each_with_index.map do |word, index|
      if word.match?(/\A[[:alpha:]]+\z/)
        lower = word.downcase
        if index.positive? && MINOR_WORDS.include?(lower) then lower
        elsif word.length <= 2 || word.match?(/\d/) then word.upcase
        else lower.capitalize
        end
      else
        word
      end
    end.join
  end

  def themes
    themes = layer.disciplines.filter_map { |discipline| THEMES[discipline] }
    themes.unshift('Imagery') if composite?
    themes.uniq
  end

  # The program, the source collections' platforms, the instruments of their satellites, and the layer's period.
  # Models and analyses aren't platforms anyone would search for, and an aircraft campaign's dozen in-situ
  # instruments say little about its imagery.
  def keywords
    platforms = layer.platforms.reject { |platform| platform['Type'].to_s.match?(/model|analys/i) }
    names = platforms.flat_map do |platform|
      instruments = SATELLITES.include?(platform['Type']) ? (platform['Instruments'] || []) : []
      [platform['ShortName'], *instruments.map { |instrument| instrument['ShortName'] }]
    end
    [KEYWORD, *names, layer.period].compact.uniq
  end

  # Vector layers' features could be points, lines or polygons, which nothing upstream says
  def resource_types
    return nil if layer.vector?
    return ['Satellite imagery'] if composite?

    [layer.remote_sensing? ? 'Remote-sensing maps' : 'Raster data']
  end

  def envelope
    self.class.format_envelope(*layer.bounds)
  end

  # "latitude,longitude" of a regional layer's center; the globe has none worth giving
  def centroid
    return nil if layer.global?

    west, south, east, north = layer.bounds
    east += 360 if east < west
    longitude = (west + east) / 2
    longitude -= 360 if longitude > 180
    "#{self.class.format_coordinate((south + north) / 2)},#{self.class.format_coordinate(longitude)}"
  end

  def rights
    [ACKNOWLEDGEMENT, *licensed_sources.map { |source| constraint_text(source) }].compact.uniq
  end

  def licenses
    licensed_sources.flat_map do |source|
      constraints = source.dig('umm', 'UseConstraints') || {}
      [constraints.dig('LicenseURL', 'Linkage'), *constraint_text(source).to_s.scan(CREATIVE_COMMONS)]
    end.compact.map { |url| url.strip.sub(%r{/?\z}, '/') }.uniq
  end

  # Source collections whose use constraints carry a licence beyond NASA's open data policy: Creative Commons, so far
  def licensed_sources
    layer.sources.select { |source| constraint_text(source).to_s.match?(/creativecommons\.org|Creative Commons/i) }
  end

  def constraint_text(source)
    constraints = source.dig('umm', 'UseConstraints')
    return nil unless constraints.is_a?(Hash)

    [constraints['Description'], constraints['LicenseText']].compact.join(' ').gsub(/\s+/, ' ').strip
  end

  # The services first, then Worldview and the thumbnail. Raster layers offer XYZ, WMTS and WMS; vector layers only
  # the Geographic WMS, which draws them as Web Mercator images, since GIBS has no Web Mercator vector tiles for them.
  # Layers published only in polar projections have nothing a Web Mercator viewer could draw.
  def references
    refs = {}
    if layer.web_mercator
      unless layer.vector?
        xyz = xyz_template
        refs[XYZ] = xyz if xyz
        refs[WMTS] = WMTS_URL
      end
      refs[WMS] = layer.vector? ? VECTOR_WMS_URL : WMS_URL
    end
    refs['http://schema.org/url'] = worldview_url if layer.worldview_config
    refs['http://schema.org/thumbnailUrl'] = thumbnail_url
    refs.compact
  end

  # GIBS's tile template with the date set to "default", which GIBS answers with the layer's latest imagery
  def xyz_template
    templates = layer.web_mercator.tile_templates
    template = templates.find { |candidate| candidate.include?('/default/default/') } ||
               templates.first&.sub('{Time}', 'default')
    return nil unless template

    url = template.sub('{TileMatrixSet}', layer.web_mercator.tile_matrix_set).sub('{TileMatrix}', '{z}')
                  .sub('{TileRow}', '{y}').sub('{TileCol}', '{x}')
    url.scan(/\{(\w+)\}/).flatten.sort == %w[x y z] ? url : nil
  end

  # Worldview with the layer on, under its coastlines unless it's a picture of the Earth already. Polar-only layers
  # open in their projection.
  def worldview_url
    layers = composite? ? layer.identifier : "Coastlines_15m,#{layer.identifier}"
    projection = if layer.polar_only?
                   layer.entries.key?('epsg3413') ? 'arctic' : 'antarctic'
                 end
    "#{WORLDVIEW_URL}?l=#{layers}#{"&p=#{projection}" if projection}"
  end

  # A small picture of the latest imagery from GIBS's WMS. The URL leaves the date out, so it never changes.
  def thumbnail_url
    if layer.entries.key?('epsg4326')
      wms_image('epsg4326', 'EPSG:4326', '-180,-90,180,90', 512, 256)
    else
      projection = layer.entries.key?('epsg3413') ? 'epsg3413' : 'epsg3031'
      wms_image(projection, "EPSG:#{projection.delete_prefix('epsg')}", '-4194304,-4194304,4194304,4194304', 512, 512)
    end
  end

  def wms_image(projection, srs, bbox, width, height)
    "https://gibs.earthdata.nasa.gov/wms/#{projection}/best/wms.cgi?SERVICE=WMS&REQUEST=GetMap&VERSION=1.1.1" \
      "&LAYERS=#{layer.identifier}&STYLES=&SRS=#{srs}&BBOX=#{bbox}&WIDTH=#{width}&HEIGHT=#{height}&FORMAT=image/jpeg"
  end
end
