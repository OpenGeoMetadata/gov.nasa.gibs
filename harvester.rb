require 'date'
require 'fileutils'
require 'json'
require 'set'
require_relative 'capabilities'
require_relative 'cmr'
require_relative 'domains'
require_relative 'http_client'
require_relative 'layer'
require_relative 'layer_metadata'
require_relative 'mapper'
require_relative 'worldview'

# Regenerates the Aardvark records in metadata-aardvark/gibs/ from what NASA publishes about the layers of its
# Global Imagery Browse Services (GIBS), and logs records that leave the repository in withdrawn.json.
#
# GIBS lists every layer on every run, so there is no incremental state to keep: each run rebuilds every record and
# writes only the files whose contents changed, and an unchanged GIBS leaves the repository untouched. What each run
# fetched is kept in tmp/snapshot, so it can be rerun offline with SOURCE=tmp/snapshot.
class Harvester
  METADATA_DIR = 'metadata-aardvark/gibs'
  WITHDRAWN_FILE = 'withdrawn.json'
  SNAPSHOT_DIR = 'tmp/snapshot'
  WORLDVIEW_DIR = 'worldview'

  WITHDRAWALS_SCHEMA = 'https://opengeometadata.org/schema/ogm-withdrawals-1.0.json'
  MODIFIED = 'gbl_mdModified_dt'

  # Refuse to withdraw anything if a run would shrink the repository by more than this fraction, so that a broken
  # source can't empty it. GIBS renames layers in batches, 20 at once early in 2026, which this allows. Rerun with
  # FORCE=1 when a bigger drop is real.
  MAX_SHRINK = 0.05

  # A pause between requests to each host, in seconds: GIBS is asked about 1,400 times a run, mostly for layer
  # metadata, and CMR about 8 times
  INTERVALS = { 'gibs.earthdata.nasa.gov' => 0.05, 'cmr.earthdata.nasa.gov' => 0.5 }.freeze

  class Error < StandardError; end

  def self.run(**options)
    new(**options).run
  end

  # Records are bucketed by the first word of their layer's identifier, e.g. modis/, which keeps every directory
  # under GitHub's 1,000-entry listing limit. A record's path follows from its id.
  def self.directories(id)
    [id.delete_prefix(Layer::ID_PREFIX).split('_').first]
  end

  attr_reader :source, :metadata_dir, :withdrawn_file, :snapshot_dir, :dry_run, :force, :max_shrink, :today, :log

  def initialize(source: nil, metadata_dir: METADATA_DIR, withdrawn_file: WITHDRAWN_FILE, snapshot_dir: SNAPSHOT_DIR,
                 dry_run: false, force: false, max_shrink: MAX_SHRINK, today: Date.today, log: $stdout, http: nil)
    @source = source
    @metadata_dir = metadata_dir
    @withdrawn_file = withdrawn_file
    @snapshot_dir = snapshot_dir
    @dry_run = dry_run
    @force = force
    @max_shrink = max_shrink
    @today = today
    @log = log
    @http = http
  end

  # @return [Hash] counts of what the run did
  def run
    capabilities, metadata, domains, @worldview, cmr = sources
    layers = build_layers(capabilities, metadata, domains, @worldview, cmr)
    published, skipped = layers.partition { |layer| layer.skip_reason.nil? }
    check_unique(published)
    existing = existing_records
    check_shrinkage(existing.size, published.size)

    counts = Hash.new(0)
    skipped.each { |layer| counts[:"skipped_#{layer.skip_reason}"] += 1 }
    shared = shared_titles(published)
    created = []
    published.each do |layer|
      record = Mapper.map(layer, distinguish: shared.include?(layer.title), modified: today)
      status = write_record(record_path(layer.id), record)
      created << layer.id if status == :created
      counts[status] += 1
    end
    counts[:collection] = write_record(collection_path, Mapper.collection(published, modified: today))
    ids = published.map(&:id).to_set
    counts.merge!(withdraw(removals(existing, ids, created, layers), ids | [Mapper::COLLECTION_ID]))

    report(layers, published, counts)
    counts
  end

  private

  # @return [Array] the capabilities, layer metadata, domains, Worldview configuration and CMR collections
  def sources
    return load_sources(source) if source

    http = @http || HttpClient.new(interval: INTERVALS)
    capabilities = Capabilities.fetch(http: http, log: log)
    metadata = LayerMetadata.fetch(capabilities.layers.keys.sort, http: http, log: log)
    domains = Domains.fetch(primary_entries(capabilities), http: http, log: log)
    worldview = Worldview.fetch(File.join(snapshot_dir, WORLDVIEW_DIR), log: log)
    cmr = Cmr.fetch(metadata.concept_ids, http: http, log: log)
    [capabilities, metadata, domains, cmr].each { |fetched| fetched.save(snapshot_dir) }
    [capabilities, metadata, domains, worldview, cmr]
  end

  def load_sources(dir)
    [Capabilities.load(dir), LayerMetadata.load(dir), Domains.load(dir), Worldview.load(File.join(dir, WORLDVIEW_DIR)),
     Cmr.load(dir)]
  end

  def primary_entries(capabilities)
    capabilities.layers.transform_values { |entries| Capabilities.primary(entries) }
  end

  def build_layers(capabilities, metadata, domains, worldview, cmr)
    capabilities.layers.sort.map do |identifier, entries|
      Layer.new(identifier, entries, metadata: metadata[identifier], worldview: worldview, collections: cmr,
                                     domain_start: domains[identifier], today: today)
    end
  end

  # Two identifiers that differ only in case or punctuation would share a record; GIBS has none, so this would be new
  def check_unique(layers)
    shared = layers.group_by(&:id).select { |_id, group| group.size > 1 }
    return if shared.empty?

    raise Error, "Layers would share a record id: #{shared.values.flatten.map(&:identifier).join(', ')}"
  end

  def check_shrinkage(existing_count, kept_count)
    return if force || existing_count.zero? || kept_count >= existing_count * (1 - max_shrink)

    raise Error, "This run would leave #{kept_count} records, down from #{existing_count}: more than " \
                 "#{(max_shrink * 100).round}% fewer. Nothing was changed; rerun with FORCE=1 if the drop is real."
  end

  # Titles more than one layer would have, which then get their identifiers added: a few pairs of layers differ only
  # in an algorithm or a source their titles don't mention
  def shared_titles(layers)
    layers.map(&:title).tally.select { |_title, count| count > 1 }.keys.to_set
  end

  def record_path(id)
    File.join(metadata_dir, *self.class.directories(id), "#{id}.json")
  end

  def collection_path
    File.join(metadata_dir, "#{Mapper::COLLECTION_ID}.json")
  end

  # Every layer's record currently in the repository, by id
  def existing_records
    Dir.glob(File.join(metadata_dir, '*', "#{Layer::ID_PREFIX}*.json")).to_h do |path|
      [File.basename(path, '.json'), path]
    end
  end

  # gbl_mdModified_dt is the date a record's content last changed. Nothing upstream dates a layer's metadata, so a
  # record whose only difference from the file already there would be the date keeps the file's.
  def write_record(path, record)
    existing = read_json(path)
    if existing&.key?(MODIFIED) && existing.except(MODIFIED) == record.except(MODIFIED)
      record = record.merge(MODIFIED => existing[MODIFIED])
    end
    write_json(path, record)
  end

  def read_json(path)
    File.exist?(path) ? JSON.parse(File.read(path, mode: 'r:bom|utf-8')) : nil
  end

  def write_json(path, data)
    write_file(path, "#{JSON.pretty_generate(data)}\n")
  end

  # Writes the file only when its contents change, so unchanged records don't show up in git
  # @return [Symbol] :created, :updated, or :unchanged
  def write_file(path, content)
    exists = File.exist?(path)
    return :unchanged if exists && File.read(path, mode: 'r:bom|utf-8') == content

    unless dry_run
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content, mode: 'w:utf-8')
    end
    exists ? :updated : :created
  end

  # The records leaving the repository, each with its withdrawal entry and the file to delete
  # @param created [Array<String>] the ids of records this run created, which may be renamed layers' new names
  def removals(existing, published, created, layers)
    by_id = layers.to_h { |layer| [layer.id, layer] }
    (existing.keys - published.to_a).sort.map do |id|
      [withdrawal(id, read_json(existing[id]) || {}, by_id[id], published, created), existing[id]]
    end
  end

  # Records that leave the repository are deleted and logged in withdrawn.json, following the proposed
  # OpenGeoMetadata withdrawal convention: deleting a file alone doesn't tell harvesters to delete the record.
  # Entries are only ever removed for records that have come back.
  # @param published [Set] the id of every record the repository now has
  def withdraw(removals, published)
    withdrawals = read_withdrawals
    republished, entries = withdrawals['withdrawn'].partition { |entry| published.include?(entry['id']) }

    removals.each do |entry, path|
      entries = entries.reject { |other| other['id'] == entry['id'] } << entry
      File.delete(path) if !dry_run && File.exist?(path)
    end

    if !dry_run && (removals.any? || republished.any?)
      remove_empty_directories
      content = JSON.pretty_generate(withdrawals.merge('withdrawn' => entries))
      File.write(withdrawn_file, "#{content}\n", mode: 'w:utf-8')
    end
    reasons = removals.map { |entry, _path| entry['reason'] }.tally
    { withdrawn: removals.size, superseded: reasons.fetch('superseded', 0), quality: reasons.fetch('quality', 0),
      republished: republished.size }
  end

  def read_withdrawals
    unless File.exist?(withdrawn_file)
      return { '$schema' => WITHDRAWALS_SCHEMA, 'ogm_version' => '1.0', 'withdrawn' => [] }
    end

    JSON.parse(File.read(withdrawn_file, mode: 'r:bom|utf-8'))
  end

  # @param record [Hash] the record being withdrawn, as it was
  # @param layer [Layer, nil] the layer, if GIBS still lists it
  def withdrawal(id, record, layer, published, created)
    entry = { 'id' => id, 'date' => today.iso8601 }
    if layer&.skip_reason == :broken
      return entry.merge('reason' => 'quality',
                         'note' => "GIBS still lists this layer, but its tiles can't be requested.")
    end
    if layer&.skip_reason == :undocumented
      return entry.merge('reason' => 'quality', 'note' => 'GIBS still lists this layer, but no longer documents it.')
    end

    replacement = replacement(record, published, created)
    return entry.merge('reason' => 'upstream-removed') unless replacement

    entry.merge('reason' => 'superseded', 'note' => 'GIBS renamed this layer; the new name has its own record.',
                'is_replaced_by' => [replacement])
  end

  # The record of the layer a removed one was renamed to: the one Worldview redirects it to, otherwise the one
  # record this run created with the same title
  def replacement(record, published, created)
    identifier = (record['dct_identifier_sm'] || []).first
    redirected = identifier && @worldview.redirect(identifier)
    return Layer.record_id(redirected) if redirected && published.include?(Layer.record_id(redirected))

    namesakes = created.select { |id| read_json(record_path(id))&.[]('dct_title_s') == record['dct_title_s'] }
    namesakes.size == 1 ? namesakes.first : nil
  end

  def remove_empty_directories
    Dir.glob(File.join(metadata_dir, '*/')).each { |dir| Dir.rmdir(dir) if Dir.empty?(dir) }
  end

  def report(layers, published, counts)
    log.puts "GIBS: #{layers.size} layers; #{published.size} get records"
    log.puts "Skipped: #{counts[:skipped_utility]} utility layers, #{counts[:skipped_broken]} whose tiles can't be " \
             "requested, #{counts[:skipped_undocumented]} without layer metadata"
    log.puts "Records: #{counts[:created]} created, #{counts[:updated]} updated, #{counts[:unchanged]} unchanged; " \
             "collection record #{counts[:collection]}"
    log.puts "Withdrawn: #{counts[:withdrawn]} (#{counts[:superseded]} renamed, #{counts[:quality]} no longer " \
             "usable); republished: #{counts[:republished]}"
    log.puts 'Dry run: nothing was written' if dry_run
  end
end

if __FILE__ == $0
  # Report progress as it happens, rather than all at the end, when the log is a file or GitHub's
  $stdout.sync = true
  begin
    Harvester.run(source: ENV['SOURCE'].to_s.empty? ? nil : ENV['SOURCE'], dry_run: !ENV['DRY_RUN'].to_s.empty?,
                  force: !ENV['FORCE'].to_s.empty?)
  rescue Harvester::Error, Capabilities::Error, LayerMetadata::Error, Domains::Error, Worldview::Error, Cmr::Error,
         Snapshot::Error, HttpClient::Error => e
    warn "Harvest stopped: #{e.message}"
    exit 1
  end
end
