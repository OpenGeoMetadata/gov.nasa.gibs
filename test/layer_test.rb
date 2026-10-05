require 'minitest/autorun'
require_relative '../cmr'
require_relative '../domains'
require_relative '../layer'
require_relative '../layer_metadata'
require_relative '../worldview'

# Layers from the fixture snapshot, which test/fixtures/README.md describes
class LayerTest < Minitest::Test
  FIXTURE = File.join(__dir__, 'fixtures', 'snapshot')
  CAPABILITIES = Capabilities.load(FIXTURE)
  METADATA = LayerMetadata.load(FIXTURE)
  DOMAINS = Domains.load(FIXTURE)
  WORLDVIEW = Worldview.load(File.join(FIXTURE, 'worldview'))
  CMR = Cmr.load(FIXTURE)
  TODAY = Date.new(2026, 10, 5)

  def layer(id, metadata: METADATA[id], collections: CMR, today: TODAY)
    Layer.new(id, CAPABILITIES.layers.fetch(id), metadata: metadata, worldview: WORLDVIEW, collections: collections,
                                                 domain_start: DOMAINS[id], today: today)
  end

  def test_record_ids_are_lowercase_with_hyphens_for_dots
    assert_equal 'nasa-gibs-modis_terra_correctedreflectance_truecolor',
                 Layer.record_id('MODIS_Terra_CorrectedReflectance_TrueColor')
    assert_equal 'nasa-gibs-misr_cloud_stereo_height_histogram_bin_0-5km_monthly',
                 Layer.record_id('MISR_Cloud_Stereo_Height_Histogram_Bin_0.5km_Monthly')
  end

  def test_utility_broken_and_undocumented_layers_are_skipped
    assert_equal :utility, layer('OrbitTracks_Aqua_Ascending').skip_reason
    assert_equal :broken, layer('CERES_Combined_TOA_Longwave_Flux_All_Sky_Daily').skip_reason
    assert_equal :undocumented, layer('Graticule_Extended').skip_reason
    assert_nil layer('MODIS_Terra_CorrectedReflectance_TrueColor').skip_reason
    assert_nil layer('GPW_Population_Density_2020').skip_reason, 'a layer without dates is still a layer'
  end

  # GIBS's capabilities have "Nitrogen Dioxide (L3, Vertical Column Troposphere, Subdaily, TEMPO)"; its layer
  # metadata, which Worldview shows, has the title and the subtitle apart
  def test_titles_are_gibss_layer_metadata
    assert_equal 'Nitrogen Dioxide (L3, Vertical Column Troposphere, Subdaily) (PROVISIONAL), TEMPO',
                 layer('TEMPO_L3_NO2_Vertical_Column_Troposphere').title
  end

  def test_capabilities_titles_are_the_last_resort
    assert_equal 'Population Density (GPW, 2020)', layer('GPW_Population_Density_2020', metadata: {}).title
  end

  def test_truncated_layers_start_where_their_domain_does
    tempo = layer('TEMPO_L3_NO2_Vertical_Column_Troposphere')

    assert_equal '2023-08-02', tempo.first_day
    assert_equal (2023..2026).to_a, tempo.years
  end

  def test_ongoing_layers_stop_being_ongoing_after_a_year_without_imagery
    assert layer('MODIS_Terra_CorrectedReflectance_TrueColor').ongoing?
    refute layer('OMPS_NOAA20_NadirMapper_AerosolIndex_360').ongoing?, 'its last imagery is from May 2025'
    assert layer('OMPS_NOAA20_NadirMapper_AerosolIndex_360', today: Date.new(2025, 6, 1)).ongoing?
  end

  def test_sources_are_the_standard_products_cmr_still_has
    sources = layer('MODIS_Terra_CorrectedReflectance_TrueColor').sources

    assert_equal %w[MOD02QKM MOD02HKM MOD021KM], (sources.map { |source| source['shortName'] })
    assert(sources.all? { |source| source['type'] == 'STD' && source['umm'] })
    assert_empty layer('MISR_Aerosol_Optical_Depth_Avg_Green_Monthly').sources
  end

  def test_bounds_come_from_the_source_collections
    assert_equal [-170.0, 10.0, -10.0, 80.0], layer('TEMPO_L3_NO2_Vertical_Column_Troposphere').bounds
    assert_equal Layer::GLOBE, layer('GHRSST_L4_MUR_Sea_Surface_Temperature').bounds
    assert_equal Layer::GLOBE, layer('MISR_Aerosol_Optical_Depth_Avg_Green_Monthly').bounds, 'nothing to go on'
  end

  def test_boxes_across_the_antimeridian_stay_narrow
    collections = { 'C1-A' => rectangles([[170, -50, -170, -30], [-175, -45, -160, -35]]) }
    metadata = METADATA['GHRSST_L4_MUR_Sea_Surface_Temperature'].merge('conceptIds' => [{ 'type' => 'STD', 'value' => 'C1-A' }])
    bounds = layer('GHRSST_L4_MUR_Sea_Surface_Temperature', metadata: metadata, collections: collections).bounds

    assert_equal [170.0, -50.0, -160.0, -30.0], bounds
  end

  def test_nearly_global_extents_count_as_global
    collections = { 'C1-A' => rectangles([[-180, -85.044, 180, 85.044]]) }
    metadata = METADATA['GHRSST_L4_MUR_Sea_Surface_Temperature'].merge('conceptIds' => [{ 'type' => 'STD', 'value' => 'C1-A' }])

    assert layer('GHRSST_L4_MUR_Sea_Surface_Temperature', metadata: metadata, collections: collections).global?
  end

  def test_polar_only_layers_fall_back_to_their_polar_box
    metadata = METADATA['MEaSUREs_Ice_Velocity_Greenland'].merge('conceptIds' => [])

    assert_equal [-180.0, 38.807151, 180.0, 90.0], layer('MEaSUREs_Ice_Velocity_Greenland', metadata: metadata).bounds
  end

  private

  def rectangles(boxes)
    rectangles = boxes.map do |west, south, east, north|
      { 'WestBoundingCoordinate' => west, 'SouthBoundingCoordinate' => south, 'EastBoundingCoordinate' => east,
        'NorthBoundingCoordinate' => north }
    end
    { 'SpatialExtent' => { 'HorizontalSpatialDomain' => { 'Geometry' => { 'BoundingRectangles' => rectangles } } } }
  end
end
