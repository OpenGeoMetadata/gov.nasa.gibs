require 'minitest/autorun'
require 'json'
require 'stringio'
require 'uri'
require_relative '../capabilities'
require_relative '../cmr'
require_relative '../domains'
require_relative '../layer_metadata'
require_relative '../worldview'

# Fetching each source, against a fake HTTP client that answers from a table of URLs
class SourcesTest < Minitest::Test
  FIXTURE = File.join(__dir__, 'fixtures', 'snapshot')

  class FakeHttp
    attr_reader :requests

    # @param answers [Hash{String, Regexp => Array(String, String)}] [status, body] by URL or pattern; anything else
    #   is a 404
    def initialize(answers)
      @answers = answers
      @requests = []
    end

    def get(url, headers: {})
      @requests << url
      _key, (status, body) = @answers.find { |key, _answer| key.is_a?(Regexp) ? key.match?(url) : key == url }
      response(status || '404', body || 'Not Found')
    end

    def response(status, body)
      type = Net::HTTPResponse::CODE_TO_OBJ.fetch(status)
      type.new('1.1', status, 'Fake').tap do |response|
        response.instance_variable_set(:@body, body)
        response.instance_variable_set(:@read, true)
      end
    end
  end

  def fixture(name)
    File.read(File.join(FIXTURE, name), mode: 'r:utf-8')
  end

  def test_capabilities_are_fetched_for_every_projection
    answers = Capabilities::PROJECTIONS.to_h do |projection|
      [Capabilities.url(projection), ['200', fixture("capabilities-#{projection}.xml")]]
    end
    capabilities = Capabilities.fetch(http: FakeHttp.new(answers), log: StringIO.new)

    assert_equal({ 'epsg4326' => 13, 'epsg3857' => 13, 'epsg3413' => 4, 'epsg3031' => 3 }, capabilities.counts)
  end

  def test_a_projection_without_layers_stops_the_run
    answers = Capabilities::PROJECTIONS.to_h do |projection|
      xml = fixture("capabilities-#{projection}.xml")
      xml = xml.gsub(%r{<Layer>.*?</Layer>}m, '') if projection == 'epsg3031'
      [Capabilities.url(projection), ['200', xml]]
    end
    error = assert_raises(Capabilities::Error) { Capabilities.fetch(http: FakeHttp.new(answers), log: StringIO.new) }

    assert_match(/epsg3031 list no layers/, error.message)
  end

  def test_layer_metadata_skips_layers_gibs_has_no_document_for
    ids = Array.new(20) { |index| "Layer_#{index}" }
    answers = { /Layer_\d+\.json\z/ => ['200', '{"title":"A layer"}'] }
    metadata = LayerMetadata.fetch(ids + ['Graticule_Extended'], http: FakeHttp.new(answers), log: StringIO.new)

    assert_equal({ 'title' => 'A layer' }, metadata['Layer_7'])
    assert_nil metadata['Graticule_Extended']
    assert_equal 20, metadata.documents.size
  end

  def test_too_many_missing_layer_metadata_documents_stop_the_run
    error = assert_raises(LayerMetadata::Error) do
      LayerMetadata.fetch(%w[A B C], http: FakeHttp.new({}), log: StringIO.new)
    end

    assert_match(/no layer metadata for 3 of 3 layers/, error.message)
  end

  def test_layer_metadata_errors_other_than_404_stop_the_run
    assert_raises(LayerMetadata::Error) do
      LayerMetadata.fetch(['A'], http: FakeHttp.new({ /A\.json/ => ['403', 'Forbidden'] }), log: StringIO.new)
    end
  end

  def test_domains_are_fetched_only_for_truncated_layers
    capabilities = Capabilities.load(FIXTURE)
    entries = capabilities.layers.transform_values { |layer| Capabilities.primary(layer) }
    url = 'https://gibs.earthdata.nasa.gov/wmts/epsg4326/best/1.0.0/TEMPO_L3_NO2_Vertical_Column_Troposphere/default/1km/all/all.xml'
    domain = '<Domains><DimensionDomain><ows:Identifier>time</ows:Identifier><Domain>2023-08-02T15:12:49Z/' \
             '2023-08-02T15:12:49Z/PT1H2M10S,2023-08-02T16:15:20Z/2026-10-05T12:00:00Z/PT1H</Domain></DimensionDomain></Domains>'
    http = FakeHttp.new({ url => ['200', domain] })
    domains = Domains.fetch(entries, http: http, log: StringIO.new)

    assert_equal [url], http.requests
    assert_equal({ 'TEMPO_L3_NO2_Vertical_Column_Troposphere' => '2023-08-02' }, domains.starts)
  end

  def test_cmr_is_asked_in_batches
    ids = Array.new(150) { |index| format('C%010d-PROV', index) }
    http = FakeHttp.new({ %r{\Ahttps://cmr\.earthdata\.nasa\.gov/} => ['200', '{"items":[]}'] })
    def http.get(url, headers: {})
      @requests << url
      ids = URI.decode_www_form(URI(url).query).filter_map { |key, value| value if key == 'concept_id[]' }
      items = ids.map { |id| { 'meta' => { 'concept-id' => id }, 'umm' => { 'EntryTitle' => id, 'Ignored' => true } } }
      response('200', JSON.generate('items' => items))
    end
    cmr = Cmr.fetch(ids, http: http, log: StringIO.new)

    assert_equal 2, http.requests.size
    assert_equal 150, cmr.collections.size
    assert_equal({ 'EntryTitle' => 'C0000000007-PROV' }, cmr['C0000000007-PROV'])
  end

  def test_cmr_missing_most_collections_stops_the_run
    http = FakeHttp.new({ %r{\Ahttps://cmr\.earthdata\.nasa\.gov/} => ['200', '{"items":[]}'] })
    error = assert_raises(Cmr::Error) { Cmr.fetch(%w[C1-A C2-A], http: http, log: StringIO.new) }

    assert_match(/only 0 of the 2 collections/, error.message)
  end

  def test_worldview_release_is_the_highest_version
    listing = "a1\trefs/tags/v4.99.0\nb2\trefs/tags/v5.10.0\nc3\trefs/tags/v5.9.1\nd4\trefs/tags/v6.0.0-rc.1\n"

    assert_equal 'v5.10.0', Worldview.latest_tag(listing)
    assert_raises(Worldview::Error) { Worldview.latest_tag('') }
  end
end
