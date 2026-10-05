require 'minitest/autorun'
require_relative '../description'

class DescriptionTest < Minitest::Test
  def paragraphs(markdown)
    Description.paragraphs(markdown)
  end

  def test_paragraphs_are_split_on_blank_lines_and_unwrapped
    assert_equal ['First line continues here.', 'Second paragraph.'],
                 paragraphs("First line\ncontinues here.\n\n\nSecond paragraph.\n")
  end

  def test_links_keep_their_text
    assert_equal ['References: MUR-JPL-L4-GLOB-v4.1 doi:/10.5067/GHGMR-4FJ04'],
                 paragraphs('References: MUR-JPL-L4-GLOB-v4.1 [doi:/10.5067/GHGMR-4FJ04](https://doi.org/10.5067/GHGMR-4FJ04)')
    assert_equal ['Orbital Track information from https://www.space-track.org/.'],
                 paragraphs('Orbital Track information from <https://www.space-track.org/>.')
    assert_equal ['the SMAP layers.'], paragraphs('the <a href="?l=SMAP" target="_blank">SMAP</a> layers.')
  end

  def test_superscripts_and_subscripts_become_unicode_where_they_can
    assert_equal ['5.5 x 3.5 km² of NO₂, in m⁻¹; above 7*'],
                 paragraphs('5.5 x 3.5 km<sup>2</sup> of NO<sub>2</sub>, in m<sup>-1</sup>; above 7<sup>*</sup>')
    assert_equal ['TH and TV'], paragraphs('T<sub>H</sub> and T<sub>V</sub>')
  end

  def test_emphasis_code_and_entities_are_unwrapped
    assert_equal ['Available for the most recent 90 days in l3m_data, about 5 μJ/sr; phyto means plant'],
                 paragraphs('Available for the **most recent 90 days** in `l3m_data`, about 5 &mu;J/sr; _phyto_ means plant')
  end

  def test_snake_case_and_lone_asterisks_survive
    assert_equal ['S5P_L2__SO2____HiR and 2 * 3'], paragraphs('S5P_L2__SO2____HiR and 2 * 3')
  end

  def test_headings_list_items_and_breaks_are_paragraphs_and_rules_go
    markdown = "### About Sulfur Dioxide\nSO2 enters the atmosphere.\n\n* Dust - magenta\n* Ash - red\n\n***\n\n" \
               'Line one<br>Line two'
    assert_equal ['About Sulfur Dioxide', 'SO2 enters the atmosphere.', 'Dust - magenta', 'Ash - red', 'Line one', 'Line two'],
                 paragraphs(markdown)
  end
end
