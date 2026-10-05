require 'minitest/autorun'
require 'json'
require_relative '../cmr'
require_relative '../domains'
require_relative '../layer_metadata'
require_relative '../mapper'
require_relative '../worldview'

# Records for real layers, from the fixture snapshot: see test/fixtures/README.md
class MapperTest < Minitest::Test
  FIXTURE = File.join(__dir__, 'fixtures', 'snapshot')
  CAPABILITIES = Capabilities.load(FIXTURE)
  METADATA = LayerMetadata.load(FIXTURE)
  DOMAINS = Domains.load(FIXTURE)
  WORLDVIEW = Worldview.load(File.join(FIXTURE, 'worldview'))
  CMR = Cmr.load(FIXTURE)
  TODAY = Date.new(2026, 10, 5)
  WMS = 'https://gibs.earthdata.nasa.gov/wms/epsg3857/best/wms.cgi'

  def layer(id)
    Layer.new(id, CAPABILITIES.layers.fetch(id), metadata: METADATA[id], worldview: WORLDVIEW, collections: CMR,
                                                 domain_start: DOMAINS[id], today: TODAY)
  end

  def map(id, **options)
    Mapper.map(layer(id), modified: TODAY, **options)
  end

  def references(id)
    JSON.parse(map(id)['dct_references_s'])
  end

  def test_true_color_record
    record = map('MODIS_Terra_CorrectedReflectance_TrueColor')

    assert_equal 'nasa-gibs-modis_terra_correctedreflectance_truecolor', record['id']
    assert_equal 'Corrected Reflectance (True Color), Terra / MODIS', record['dct_title_s']
    assert_equal ['MCST Team'], record['dct_creator_sm']
    assert_equal ['United States. National Aeronautics and Space Administration'], record['dct_publisher_sm']
    assert_equal ['2000-02-24 to present'], record['dct_temporal_sm']
    assert_equal (2000..2026).to_a, record['gbl_indexYear_im']
    assert_equal ['[2000 TO 2026]'], record['gbl_dateRange_drsim']
    assert_equal ['MODIS_Terra_CorrectedReflectance_TrueColor'], record['dct_identifier_sm']
    assert_equal ['Corrected Reflectance', 'Infrared Radiance', 'Reflected Infrared', 'Visible Radiance'],
                 record['dct_subject_sm']
    assert_equal ['Imagery', 'Land Cover'], record['dcat_theme_sm']
    assert_equal ['Global Imagery Browse Services', 'Terra', 'MODIS', 'Daily'], record['dcat_keyword_sm']
    assert_equal ['Imagery'], record['gbl_resourceClass_sm']
    assert_equal ['Satellite imagery'], record['gbl_resourceType_sm']
    assert_equal 'JPEG', record['dct_format_s']
    assert_equal 'ENVELOPE(-180, 180, 90, -90)', record['dcat_bbox']
    refute record.key?('dcat_centroid'), 'the globe has no centroid worth giving'
    assert_equal ['nasa-gibs'], record['pcdm_memberOf_sm']
    assert_equal [Mapper::ACKNOWLEDGEMENT], record['dct_rights_sm']
    refute record.key?('dct_license_sm')
    assert_equal '2026-10-05T00:00:00Z', record['gbl_mdModified_dt']
    assert_equal 'MODIS_Terra_CorrectedReflectance_TrueColor', record['gbl_wxsIdentifier_s']
  end

  # Worldview's description, with its references replaced by a paragraph naming the source collections
  def test_description_ends_with_what_gibs_made_the_layer_from
    description = map('GHRSST_L4_MUR_Sea_Surface_Temperature')['dct_description_sm']

    assert_match(/\AThe Sea Surface Temperature \(L4, MUR\) layer is created from/, description.first)
    refute(description.any? { |paragraph| paragraph.start_with?('References') })
    assert_equal "A daily visualization from NASA's Global Imagery Browse Services (GIBS), available from 2002-06-01 " \
                 'and updated as new data arrive. Made from GHRSST Level 4 MUR Global Foundation Sea Surface ' \
                 'Temperature Analysis (v4.1) (MUR-JPL-L4-GLOB-v4.1, version 4.1, doi:10.5067/GHGMR-4FJ04).',
                 description.last
  end

  def test_raster_layers_offer_xyz_wmts_and_wms
    refs = references('MODIS_Terra_CorrectedReflectance_TrueColor')

    assert_equal [Mapper::XYZ, Mapper::WMTS, Mapper::WMS, 'http://schema.org/url', 'http://schema.org/thumbnailUrl'],
                 refs.keys
    assert_equal 'https://gibs.earthdata.nasa.gov/wmts/epsg3857/best/MODIS_Terra_CorrectedReflectance_TrueColor/default/default/GoogleMapsCompatible_Level9/{z}/{y}/{x}.jpeg',
                 refs[Mapper::XYZ]
    assert_equal 'https://gibs.earthdata.nasa.gov/wmts/epsg3857/best/1.0.0/WMTSCapabilities.xml', refs[Mapper::WMTS]
    assert_equal WMS, refs[Mapper::WMS]
    assert_equal 'https://worldview.earthdata.nasa.gov/?l=MODIS_Terra_CorrectedReflectance_TrueColor',
                 refs['http://schema.org/url']
    assert_equal 'https://gibs.earthdata.nasa.gov/wms/epsg4326/best/wms.cgi?SERVICE=WMS&REQUEST=GetMap&VERSION=1.1.1' \
                 '&LAYERS=MODIS_Terra_CorrectedReflectance_TrueColor&STYLES=&SRS=EPSG:4326&BBOX=-180,-90,180,90' \
                 '&WIDTH=512&HEIGHT=256&FORMAT=image/jpeg', refs['http://schema.org/thumbnailUrl']
  end

  # GIBS has no Web Mercator vector tiles, so a WMS that draws them is all a viewer could use: the Geographic one,
  # since the Web Mercator one doesn't serve vector layers
  def test_vector_layers_offer_only_the_geographic_wms
    record = map('GRanD_Dams')
    refs = JSON.parse(record['dct_references_s'])

    assert_equal [Mapper::WMS, 'http://schema.org/url', 'http://schema.org/thumbnailUrl'], refs.keys
    assert_equal 'https://gibs.earthdata.nasa.gov/wms/epsg4326/best/wms.cgi', refs[Mapper::WMS]
    assert_equal ['Datasets'], record['gbl_resourceClass_sm']
    assert_equal 'Mapbox Vector Tile', record['dct_format_s']
    refute record.key?('gbl_resourceType_sm')
  end

  def test_overlays_open_in_worldview_under_its_coastlines
    assert_equal 'https://worldview.earthdata.nasa.gov/?l=Coastlines_15m,GHRSST_L4_MUR_Sea_Surface_Temperature',
                 references('GHRSST_L4_MUR_Sea_Surface_Temperature')['http://schema.org/url']
  end

  def test_polar_only_layers_have_nothing_to_preview_but_a_polar_thumbnail
    record = map('MEaSUREs_Ice_Velocity_Greenland')
    refs = JSON.parse(record['dct_references_s'])

    assert_equal ['http://schema.org/url', 'http://schema.org/thumbnailUrl'], refs.keys
    assert_equal 'https://worldview.earthdata.nasa.gov/?l=Coastlines_15m,MEaSUREs_Ice_Velocity_Greenland&p=arctic',
                 refs['http://schema.org/url']
    assert_match(%r{/wms/epsg3413/best/wms\.cgi\?.*&SRS=EPSG:3413&BBOX=-4194304,-4194304,4194304,4194304&WIDTH=512&HEIGHT=512},
                 refs['http://schema.org/thumbnailUrl'])
    refute record.key?('gbl_wxsIdentifier_s')
    assert_equal 'ENVELOPE(-75, -14, 83, 60)', record['dcat_bbox']
  end

  def test_regional_layers_get_their_source_extent_and_centroid
    record = map('TEMPO_L3_NO2_Vertical_Column_Troposphere')

    assert_equal 'ENVELOPE(-170, -10, 80, 10)', record['dcat_bbox']
    assert_equal record['dcat_bbox'], record['locn_geometry']
    assert_equal '45,-90', record['dcat_centroid']
    assert_equal ['2023-08-02 to present'], record['dct_temporal_sm']
  end

  def test_a_layer_without_dates_has_no_temporal_fields
    record = map('GPW_Population_Density_2020')

    %w[dct_temporal_sm gbl_indexYear_im gbl_dateRange_drsim].each { |field| refute record.key?(field), field }
    assert_match(/\AA visualization from NASA's Global Imagery Browse Services \(GIBS\)\. Made from/,
                 record['dct_description_sm'].last)
  end

  def test_creative_commons_constraints_become_rights_and_a_licence
    record = map('GPW_Population_Density_2020')

    assert_equal ['https://creativecommons.org/licenses/by/4.0/'], record['dct_license_sm']
    assert_equal 2, record['dct_rights_sm'].size
    assert_match(/Creative Commons Attribution 4\.0/, record['dct_rights_sm'].last)
    assert_equal ['Raster data'], record['gbl_resourceType_sm'], 'GPW is modelled, not observed'
  end

  def test_a_layer_gibs_wrongly_calls_ongoing_gives_its_last_date
    assert_equal ['2025-04-28 to 2025-05-05'], map('OMPS_NOAA20_NadirMapper_AerosolIndex_360')['dct_temporal_sm']
  end

  def test_a_single_date_on_new_years_day_is_a_year
    assert_equal ['1998'], map('LIS_Very_High_Resolution_Lightning_Full_Climatology_LIS_Mean_Flash_Rate')['dct_temporal_sm']
  end

  # Without collections to name, Worldview's own references stay
  def test_a_layer_whose_collections_are_gone_keeps_worldviews_references
    record = map('MISR_Aerosol_Optical_Depth_Avg_Green_Monthly')

    assert_includes record['dct_description_sm'], 'References: MIL3MAE_L3 doi:10.5067/Terra/MISR/MIL3MAE_L3.004'
    assert record['dct_description_sm'].last.end_with?('covering 2000-03-01 to 2022-02-01.')
    refute record.key?('dct_creator_sm')
  end

  # Not in Worldview, so its description starts with what GIBS made it from, then the collection's abstract
  def test_a_layer_worldview_doesnt_describe_gets_its_collections_abstract
    record = map('DISCOVER-AQ_TX_P3B_Ozone')

    assert_equal 2, record['dct_description_sm'].size
    assert_match(/\AA daily visualization .+ Made from DISCOVER-AQ Texas Deployment/, record['dct_description_sm'].first)
    assert_match(/\ADISCOVERAQ_Texas_MetNav_AircraftInSitu_P3B_Data contains/, record['dct_description_sm'].last)
    refute JSON.parse(record['dct_references_s']).key?('http://schema.org/url'), 'Worldview has no view of it'
  end

  def test_aircraft_instruments_are_left_out_of_keywords
    assert_equal ['Global Imagery Browse Services', 'P-3B', 'Daily'], map('DISCOVER-AQ_TX_P3B_Ozone')['dcat_keyword_sm']
  end

  def test_titles_shared_with_another_layer_add_the_identifier
    assert_equal 'Chlorophyll a, SeaWiFS / Orbview-2 (SEAWIFS_ORBVIEW-2_GAC_Chlorophyll_a)',
                 map('SEAWIFS_ORBVIEW-2_GAC_Chlorophyll_a', distinguish: true)['dct_title_s']
  end

  def test_gcmd_keywords_become_headings
    mapper = Mapper.new(layer('GHRSST_L4_MUR_Sea_Surface_Temperature'))

    assert_equal 'Sea Surface Temperature', mapper.send(:heading, 'SEA SURFACE TEMPERATURE')
    assert_equal 'Aerosol Optical Depth/Thickness', mapper.send(:heading, 'AEROSOL OPTICAL DEPTH/THICKNESS')
    assert_equal 'UV Index of the Day', mapper.send(:heading, 'UV INDEX OF THE DAY')
  end

  def test_collection_record_summarizes_its_layers
    layers = %w[MODIS_Terra_CorrectedReflectance_TrueColor SEAWIFS_ORBVIEW-2_GAC_Chlorophyll_a].map { |id| layer(id) }
    record = Mapper.collection(layers, modified: TODAY)

    assert_equal 'nasa-gibs', record['id']
    assert_equal ['Collections'], record['gbl_resourceClass_sm']
    assert_equal ['1997-2026'], record['dct_temporal_sm']
    assert_equal ['[1997 TO 2026]'], record['gbl_dateRange_drsim']
    assert_equal({ 'http://schema.org/url' => 'https://nasa-gibs.github.io/gibs-api-docs/' },
                 JSON.parse(record['dct_references_s']))
  end
end
