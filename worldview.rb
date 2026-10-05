require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'
require_relative 'description'

# What Worldview, NASA's browser for GIBS, says about each layer: the description it shows, overrides for the titles
# GIBS gives, the measurement and science disciplines it files the layer under, and redirects for renamed layers.
#
# All of it comes from the configuration in Worldview's repository, as of its latest release. The deployed site's
# combined wv.json would do, but it's always sent Brotli-compressed, which Ruby can't decode, so the harvester takes
# a sparse clone of just the configuration instead: a few seconds and 15 MB.
class Worldview
  REPOSITORY = 'https://github.com/nasa-gibs/worldview.git'
  CONFIG = 'config/default/common/config'

  # Where each part of the configuration is in Worldview's repository, and where the snapshot keeps it. The snapshot
  # flattens the layout, leaving out the repository's wv.json directory, which tools looking for JSON records take
  # for a file.
  LAYOUT = {
    "#{CONFIG}/wv.json/layers" => 'layers',
    "#{CONFIG}/wv.json/measurements" => 'measurements',
    "#{CONFIG}/wv.json/categories" => 'categories',
    "#{CONFIG}/wv.json/redirects.json" => 'redirects.json',
    "#{CONFIG}/metadata/layers" => 'descriptions'
  }.freeze

  RELEASE_FILE = 'RELEASE'

  # The category group whose categories become themes
  DISCIPLINES = 'science disciplines'

  class Error < StandardError; end

  # Clones the latest release's configuration and copies it into `dir`, replacing whatever was there
  def self.fetch(dir, log: $stdout)
    tag = latest_release
    Dir.mktmpdir('worldview') do |tmp|
      checkout = File.join(tmp, 'worldview')
      git('-c', 'advice.detachedHead=false', 'clone', '--quiet', '--depth', '1', '--branch', tag, '--filter=blob:none',
          '--sparse', REPOSITORY, checkout)
      # Sparse checkout takes the files directly inside a directory's parents too, which brings redirects.json
      git('-C', checkout, 'sparse-checkout', 'set', *LAYOUT.keys.reject { |path| path.end_with?('.json') })
      copy(checkout, dir, tag)
    end
    load(dir).tap { |worldview| log.puts "Worldview #{tag}: #{worldview.layers.size} layers" }
  end

  # Copies the configuration out of a checkout of Worldview's repository, into the snapshot's layout
  def self.copy(checkout, dir, release)
    FileUtils.rm_rf(dir)
    FileUtils.mkdir_p(dir)
    LAYOUT.each do |from, to|
      source = File.join(checkout, from)
      FileUtils.cp_r(source, File.join(dir, to)) if File.exist?(source)
    end
    File.write(File.join(dir, RELEASE_FILE), "#{release}\n")
  end

  def self.latest_release
    latest_tag(git('ls-remote', '--tags', '--refs', REPOSITORY, 'v*'))
  end

  # The highest version among the release tags `git ls-remote` lists, e.g. v5.6.0; release candidates don't count
  def self.latest_tag(listing)
    tags = listing.scan(%r{refs/tags/(v\d+\.\d+\.\d+)$}).flatten
    raise Error, "#{REPOSITORY} has no release tags" if tags.empty?

    tags.max_by { |tag| tag.delete_prefix('v').split('.').map(&:to_i) }
  end

  def self.git(*args)
    output, status = Open3.capture2e({ 'GIT_TERMINAL_PROMPT' => '0' }, 'git', *args)
    raise Error, "git #{args.join(' ')} failed: #{output.strip}" unless status.success?

    output
  end

  def self.load(dir)
    raise Error, "No Worldview configuration at #{dir}" unless Dir.exist?(File.join(dir, 'layers'))

    new(dir)
  end

  attr_reader :dir, :layers, :release

  def initialize(dir)
    @dir = dir
    @release = File.exist?(File.join(dir, RELEASE_FILE)) ? File.read(File.join(dir, RELEASE_FILE)).strip : nil
    @layers = read_all('layers/**/*.json').map { |config| config['layers'] || {} }.reduce({}, :merge)
    raise Error, "The Worldview configuration at #{dir} has no layers" if @layers.empty?
  end

  # The layer's configuration, or nil for a layer Worldview doesn't show
  def [](id)
    layers[id]
  end

  # The layer's description as paragraphs of plain text, or none if Worldview has no description for it
  def description(id)
    path = layers.dig(id, 'description')
    file = path && File.join(dir, 'descriptions', "#{path}.md")
    file && File.exist?(file) ? Description.paragraphs(File.read(file, mode: 'r:bom|utf-8')) : []
  end

  # The science disciplines whose measurements list the layer, e.g. ["Atmosphere", "Oceans"]. A layer that Worldview
  # doesn't list under any measurement is filed by the measurement GIBS gives it.
  def disciplines(id, measurement: nil)
    measurements = measurements_by_layer.fetch(id) { [measurement].compact }
    disciplines_by_measurement.select { |_discipline, listed| listed.intersect?(measurements) }.keys.sort
  end

  # The layer a renamed one is now called, as Worldview redirects permalinks to it
  def redirect(id)
    redirects[id]
  end

  private

  def read_all(pattern)
    Dir.glob(File.join(dir, pattern)).sort.map { |path| JSON.parse(File.read(path, mode: 'r:bom|utf-8')) }
  end

  # The measurements each layer is a source setting of
  def measurements_by_layer
    @measurements_by_layer ||= read_all('measurements/*.json').each_with_object({}) do |file, index|
      (file['measurements'] || {}).each do |name, measurement|
        (measurement['sources'] || {}).each_value do |source|
          (source['settings'] || []).each { |id| (index[id] ||= []) << name }
        end
      end
    end
  end

  def disciplines_by_measurement
    @disciplines_by_measurement ||= read_all('categories/**/*.json').each_with_object({}) do |file, index|
      (file.dig('categories', DISCIPLINES) || {}).each do |name, category|
        index[name] = category['measurements'] || [] unless name == 'All'
      end
    end
  end

  def redirects
    @redirects ||= begin
      path = File.join(dir, 'redirects.json')
      File.exist?(path) ? JSON.parse(File.read(path, mode: 'r:bom|utf-8')).dig('redirects', 'layers') || {} : {}
    end
  end
end
