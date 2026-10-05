require 'minitest/autorun'
require 'fileutils'
require 'json'
require 'stringio'
require 'tmpdir'
require_relative '../harvester'

# Harvests from the fixture snapshot, a real one cut down to 15 layers: see test/fixtures/README.md. Three of them get
# no record: an orbit track, a layer whose tiles can't be requested, and one without layer metadata.
class HarvesterTest < Minitest::Test
  FIXTURE = File.join(__dir__, 'fixtures', 'snapshot')
  TODAY = Date.new(2026, 10, 5)
  RECORDS = 12

  def setup
    @tmp_dir = Dir.mktmpdir
    @metadata_dir = File.join(@tmp_dir, 'metadata-aardvark', 'gibs')
    @withdrawn_file = File.join(@tmp_dir, 'withdrawn.json')
    @sources = 0
  end

  def teardown
    FileUtils.rm_rf(@tmp_dir)
  end

  # A copy of the fixture snapshot, for a test to change
  def snapshot
    dir = File.join(@tmp_dir, "snapshot-#{@sources += 1}")
    FileUtils.cp_r(FIXTURE, dir)
    yield dir if block_given?
    dir
  end

  def harvest(source = FIXTURE, today: TODAY, **options)
    Harvester.run(source: source, metadata_dir: @metadata_dir, withdrawn_file: @withdrawn_file, today: today,
                  log: StringIO.new, **options)
  end

  def record_path(id)
    File.join(@metadata_dir, *Harvester.directories(id), "#{id}.json")
  end

  def record(id)
    JSON.parse(File.read(record_path(id), mode: 'r:utf-8'))
  end

  def withdrawals
    JSON.parse(File.read(@withdrawn_file, mode: 'r:utf-8'))['withdrawn']
  end

  # Rewrites every capabilities document in a snapshot
  def edit_capabilities(dir)
    Capabilities::PROJECTIONS.each do |projection|
      path = File.join(dir, Capabilities.file(projection))
      doc = REXML::Document.new(File.read(path, mode: 'r:utf-8'))
      yield doc.root.elements['Contents'], projection
      File.write(path, doc.to_s, mode: 'w:utf-8')
    end
  end

  def layer_elements(contents, id)
    contents.get_elements('Layer').select { |layer| layer.elements['ows:Identifier'].text == id }
  end

  def edit_metadata(dir)
    path = File.join(dir, LayerMetadata::FILE)
    rows = File.readlines(path, mode: 'r:utf-8').map { |line| JSON.parse(line) }
    rows = yield rows
    File.write(path, rows.map { |row| "#{JSON.generate(row)}\n" }.join, mode: 'w:utf-8')
  end

  def remove_layer(dir, id)
    edit_capabilities(dir) { |contents| layer_elements(contents, id).each { |layer| contents.delete_element(layer) } }
    edit_metadata(dir) { |rows| rows.reject { |row| row['id'] == id } }
  end

  # The layer as GIBS would list it after renaming it
  def rename_layer(dir, from, to)
    edit_capabilities(dir) { |contents| layer_elements(contents, from).each { |layer| layer.elements['ows:Identifier'].text = to } }
    edit_metadata(dir) { |rows| rows.map { |row| row['id'] == from ? row.merge('id' => to) : row } }
  end

  def test_writes_a_record_per_layer_in_its_buckets_directory
    counts = harvest

    assert_equal RECORDS, counts[:created]
    assert_equal :created, counts[:collection]
    assert File.exist?(File.join(@metadata_dir, 'modis', 'nasa-gibs-modis_terra_correctedreflectance_truecolor.json'))
    assert File.exist?(File.join(@metadata_dir, 'discover-aq', 'nasa-gibs-discover-aq_tx_p3b_ozone.json'))
    assert File.exist?(File.join(@metadata_dir, 'nasa-gibs.json'))
    refute File.exist?(@withdrawn_file), 'nothing was withdrawn, so there should be no log'
  end

  def test_skips_utility_broken_and_undocumented_layers
    counts = harvest

    assert_equal 1, counts[:skipped_utility]
    assert_equal 1, counts[:skipped_broken]
    assert_equal 1, counts[:skipped_undocumented]
    refute File.exist?(record_path('nasa-gibs-orbittracks_aqua_ascending'))
  end

  def test_files_are_pretty_printed_utf8_with_a_trailing_newline
    harvest
    content = File.read(record_path('nasa-gibs-grand_dams'), mode: 'r:utf-8')

    assert content.start_with?("{\n  \"id\": \"nasa-gibs-grand_dams\",")
    assert content.end_with?("}\n")
  end

  def test_titles_two_layers_share_get_their_identifiers
    harvest

    assert_equal 'Chlorophyll a, SeaWiFS / Orbview-2 (SEAWIFS_ORBVIEW-2_MLAC_Chlorophyll_a)',
                 record('nasa-gibs-seawifs_orbview-2_mlac_chlorophyll_a')['dct_title_s']
    assert_equal 'Corrected Reflectance (True Color), Terra / MODIS',
                 record('nasa-gibs-modis_terra_correctedreflectance_truecolor')['dct_title_s']
  end

  def test_second_run_changes_nothing
    harvest
    counts = harvest

    assert_equal 0, counts[:created]
    assert_equal 0, counts[:updated]
    assert_equal RECORDS, counts[:unchanged]
    assert_equal :unchanged, counts[:collection]
  end

  # Nothing upstream dates a layer's metadata, so the date is when the record last changed
  def test_modified_date_moves_only_when_a_record_changes
    harvest
    source = snapshot do |dir|
      edit_metadata(dir) do |rows|
        rows.map { |row| row['id'] == 'GRanD_Dams' ? row.merge('metadata' => row['metadata'].merge('title' => 'Dam Locations')) : row }
      end
    end
    counts = harvest(source, today: TODAY + 3)

    assert_equal 1, counts[:updated]
    assert_equal '2026-10-08T00:00:00Z', record('nasa-gibs-grand_dams')['gbl_mdModified_dt']
    assert_match(/\ADam Locations, /, record('nasa-gibs-grand_dams')['dct_title_s'])
    assert_equal '2026-10-05T00:00:00Z', record('nasa-gibs-gpw_population_density_2020')['gbl_mdModified_dt']
  end

  def test_withdraws_layers_that_leave_gibs
    harvest
    counts = harvest(snapshot { |dir| remove_layer(dir, 'GRanD_Dams') }, max_shrink: 1.0)

    assert_equal 1, counts[:withdrawn]
    refute File.exist?(record_path('nasa-gibs-grand_dams'))
    log = JSON.parse(File.read(@withdrawn_file, mode: 'r:utf-8'))
    assert_equal 'https://opengeometadata.org/schema/ogm-withdrawals-1.0.json', log['$schema']
    assert_equal [{ 'id' => 'nasa-gibs-grand_dams', 'date' => '2026-10-05', 'reason' => 'upstream-removed' }],
                 log['withdrawn']
  end

  # Its tile templates still ask for a date, but the capabilities no longer offer any
  def test_a_layer_whose_tiles_cant_be_requested_is_withdrawn_for_quality
    harvest
    source = snapshot do |dir|
      edit_capabilities(dir) do |contents|
        layer_elements(contents, 'MODIS_Terra_CorrectedReflectance_TrueColor').each do |layer|
          layer.delete_element(layer.elements['Dimension'])
        end
      end
    end
    counts = harvest(source, max_shrink: 1.0)

    assert_equal 1, counts[:quality]
    assert_equal 'quality', withdrawals.first['reason']
    assert_match(/can't be requested/, withdrawals.first['note'])
  end

  def test_a_renamed_layer_is_superseded_by_its_new_name
    harvest
    counts = harvest(snapshot { |dir| rename_layer(dir, 'GRanD_Dams', 'GRanD_Dams_v1') }, max_shrink: 1.0)

    assert_equal 1, counts[:superseded]
    assert_equal 1, counts[:created]
    entry = withdrawals.first
    assert_equal 'nasa-gibs-grand_dams', entry['id']
    assert_equal 'superseded', entry['reason']
    assert_equal ['nasa-gibs-grand_dams_v1'], entry['is_replaced_by']
  end

  # A new title rules out matching by title, but Worldview's redirect still says where the layer went
  def test_a_layer_worldview_redirects_is_superseded_by_the_redirects_target
    harvest
    source = snapshot do |dir|
      rename_layer(dir, 'GRanD_Dams', 'GRanD_Dams_v2')
      edit_metadata(dir) do |rows|
        rows.map { |row| row['id'] == 'GRanD_Dams_v2' ? row.merge('metadata' => row['metadata'].merge('title' => 'Dams v2')) : row }
      end
      redirects = File.join(dir, 'worldview', Worldview::CONFIG, 'wv.json', 'redirects.json')
      config = JSON.parse(File.read(redirects, mode: 'r:utf-8'))
      config['redirects']['layers']['GRanD_Dams'] = 'GRanD_Dams_v2'
      File.write(redirects, JSON.generate(config))
    end
    harvest(source, max_shrink: 1.0)

    assert_equal ['nasa-gibs-grand_dams_v2'], withdrawals.first['is_replaced_by']
  end

  def test_republished_layer_leaves_the_log
    harvest
    harvest(snapshot { |dir| remove_layer(dir, 'GRanD_Dams') }, max_shrink: 1.0)
    counts = harvest(FIXTURE, max_shrink: 1.0)

    assert_equal 1, counts[:republished]
    assert_empty withdrawals
    assert record('nasa-gibs-grand_dams')
  end

  # GRanD is the only layer in its bucket, which goes with it
  def test_emptied_directories_are_removed
    harvest
    harvest(snapshot { |dir| remove_layer(dir, 'GRanD_Dams') }, max_shrink: 1.0)

    refute Dir.exist?(File.join(@metadata_dir, 'grand'))
    assert Dir.exist?(File.join(@metadata_dir, 'gpw'))
  end

  def test_refuses_to_withdraw_after_a_large_drop
    harvest
    error = assert_raises(Harvester::Error) { harvest(snapshot { |dir| remove_layer(dir, 'GRanD_Dams') }) }

    assert_match(/down from #{RECORDS}/, error.message)
    assert record('nasa-gibs-grand_dams'), 'no records should be removed'
    refute File.exist?(@withdrawn_file)
  end

  def test_force_allows_a_large_drop
    harvest
    counts = harvest(snapshot { |dir| remove_layer(dir, 'GRanD_Dams') }, force: true)

    assert_equal 1, counts[:withdrawn]
  end

  def test_layers_that_would_share_a_record_id_stop_the_run
    source = snapshot do |dir|
      edit_capabilities(dir) do |contents|
        layer_elements(contents, 'GRanD_Dams').each do |layer|
          copy = layer.deep_clone
          copy.elements['ows:Identifier'].text = 'GRAND_DAMS'
          contents.add_element(copy)
        end
      end
      edit_metadata(dir) { |rows| rows + rows.select { |row| row['id'] == 'GRanD_Dams' }.map { |row| row.merge('id' => 'GRAND_DAMS') } }
    end
    error = assert_raises(Harvester::Error) { harvest(source) }

    assert_match(/GRAND_DAMS, GRanD_Dams|GRanD_Dams, GRAND_DAMS/, error.message)
  end

  def test_dry_run_writes_nothing
    counts = harvest(dry_run: true)

    assert_equal RECORDS, counts[:created]
    refute Dir.exist?(@metadata_dir)
  end
end
