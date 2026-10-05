require 'minitest/autorun'
require 'fileutils'
require 'tmpdir'
require_relative '../capabilities'
require_relative '../domains'

# The fixture's capabilities documents: see test/fixtures/README.md
class CapabilitiesTest < Minitest::Test
  FIXTURE = File.join(__dir__, 'fixtures', 'snapshot')
  CAPABILITIES = Capabilities.load(FIXTURE)

  def entries(id)
    CAPABILITIES.layers.fetch(id)
  end

  def test_layers_are_keyed_by_identifier_and_projection
    assert_equal 15, CAPABILITIES.layers.size
    assert_equal %w[epsg4326 epsg3857 epsg3413 epsg3031], entries('MODIS_Terra_CorrectedReflectance_TrueColor').keys
    assert_equal %w[epsg3413], entries('MEaSUREs_Ice_Velocity_Greenland').keys
  end

  def test_an_entry_has_what_the_records_need
    entry = entries('MODIS_Terra_CorrectedReflectance_TrueColor')['epsg3857']

    assert_equal 'Corrected Reflectance (True Color, MODIS, Terra)', entry.title
    assert_equal [-180.0, -85.051129, 180.0, 85.051129], entry.bbox
    assert_equal 'image/jpeg', entry.format
    assert_equal 'GoogleMapsCompatible_Level9', entry.tile_matrix_set
    assert_equal 3, entry.tile_templates.size
    assert_includes entry.tile_templates,
                    'https://gibs.earthdata.nasa.gov/wmts/epsg3857/best/MODIS_Terra_CorrectedReflectance_TrueColor/default/default/{TileMatrixSet}/{TileMatrix}/{TileRow}/{TileCol}.jpeg'
    assert_equal 5, entry.domain_templates.size
  end

  def test_time_dimensions_give_their_first_and_last_days
    time = entries('MODIS_Terra_CorrectedReflectance_TrueColor')['epsg4326'].time

    assert_equal '2000-02-24', time.first_day
    assert_equal '2026-10-05', time.last_day
    refute time.truncated?
    assert_nil entries('GPW_Population_Density_2020')['epsg4326'].time
  end

  # GIBS lists the latest 100 periods, so a sub-daily layer's list starts a week ago
  def test_a_layer_listing_100_periods_is_truncated
    time = entries('TEMPO_L3_NO2_Vertical_Column_Troposphere')['epsg4326'].time

    assert time.truncated?
    assert_equal '2026-09-28', time.first_day
  end

  def test_polar_bounding_boxes_are_kept
    assert_equal [-180.0, 38.807151, 180.0, 90.0], entries('MEaSUREs_Ice_Velocity_Greenland')['epsg3413'].bbox
  end

  def test_the_primary_entry_is_geographic_then_web_mercator_then_polar
    assert_equal entries('GRanD_Dams')['epsg4326'], Capabilities.primary(entries('GRanD_Dams'))
    assert_equal entries('MEaSUREs_Ice_Velocity_Greenland')['epsg3413'],
                 Capabilities.primary(entries('MEaSUREs_Ice_Velocity_Greenland'))
  end

  def test_domains_document_covers_every_place_and_period
    entry = entries('TEMPO_L3_NO2_Vertical_Column_Troposphere')['epsg4326']

    assert_equal 'https://gibs.earthdata.nasa.gov/wmts/epsg4326/best/1.0.0/TEMPO_L3_NO2_Vertical_Column_Troposphere/default/1km/all/all.xml',
                 Domains.url(entry)
    assert_equal '2023-08-02',
                 Domains.first_day('<Domain>2023-08-02T15:12:49Z/2023-08-02T15:12:49Z/PT1H,2024-01-01/2026-10-05/P1D</Domain>')
    assert_nil Domains.first_day('<Domains></Domains>')
  end

  def test_snapshot_round_trips
    dir = Dir.mktmpdir
    CAPABILITIES.save(dir)

    assert_equal CAPABILITIES.counts, Capabilities.load(dir).counts
  ensure
    FileUtils.rm_rf(dir)
  end
end
