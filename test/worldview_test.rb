require 'minitest/autorun'
require_relative '../worldview'

# The fixture's cut of Worldview's configuration: see test/fixtures/README.md
class WorldviewTest < Minitest::Test
  WORLDVIEW = Worldview.load(File.join(__dir__, 'fixtures', 'snapshot', 'worldview'))

  def test_reads_the_release_and_every_layer
    assert_equal 'v5.6.0', WORLDVIEW.release
    assert_equal 10, WORLDVIEW.layers.size
    assert_equal 'modis/terra/MODIS_Terra_CorrectedReflectance_TrueColor',
                 WORLDVIEW['MODIS_Terra_CorrectedReflectance_TrueColor']['description']
    assert_nil WORLDVIEW['SEAWIFS_ORBVIEW-2_MLAC_Chlorophyll_a']
  end

  def test_descriptions_are_plain_paragraphs
    paragraphs = WORLDVIEW.description('TEMPO_L3_NO2_Vertical_Column_Troposphere')

    assert_equal 5, paragraphs.size
    assert paragraphs.first.end_with?('on the Earth’s surface (molecules/cm²).'), paragraphs.first
    assert paragraphs.last.start_with?('References: TEMPO_NO2_L3'), paragraphs.last
    assert_empty WORLDVIEW.description('SEAWIFS_ORBVIEW-2_MLAC_Chlorophyll_a')
  end

  def test_disciplines_come_from_the_measurements_listing_a_layer
    assert_equal %w[Cryosphere Oceans], WORLDVIEW.disciplines('GHRSST_L4_MUR_Sea_Surface_Temperature')
    assert_equal ['Human Dimensions'], WORLDVIEW.disciplines('GPW_Population_Density_2020')
  end

  # MLAC isn't in Worldview, so it's filed under the measurement GIBS gives it
  def test_a_layer_worldview_doesnt_list_is_filed_by_its_measurement
    assert_equal ['Oceans'], WORLDVIEW.disciplines('SEAWIFS_ORBVIEW-2_MLAC_Chlorophyll_a', measurement: 'Chlorophyll a')
    assert_empty WORLDVIEW.disciplines('SEAWIFS_ORBVIEW-2_MLAC_Chlorophyll_a')
  end

  def test_redirects_name_renamed_layers
    assert_equal 'Graticule_15m', WORLDVIEW.redirect('Graticule')
    assert_nil WORLDVIEW.redirect('GRanD_Dams')
  end

  def test_a_directory_without_the_configuration_is_an_error
    assert_raises(Worldview::Error) { Worldview.load(__dir__) }
  end
end
