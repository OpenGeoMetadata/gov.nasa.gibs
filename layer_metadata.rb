require 'json'
require 'uri'
require_relative 'http_client'
require_relative 'snapshot'

# GIBS's own description of each layer: its title and subtitle (platform and instrument), the measurement it shows,
# its period, whether it's ongoing, and the CMR collections it's made from. Worldview's layer list is built from
# these documents. There's no description among them.
class LayerMetadata
  URL = 'https://gibs.earthdata.nasa.gov/layer-metadata/v1.0/'
  FILE = 'layer-metadata.jsonl'

  # GIBS has no document for a handful of its layers, which get no record. Many more missing than that means the
  # service is failing, and the run stops rather than withdraw layers on the strength of it.
  MAX_MISSING = 0.05

  class Error < StandardError; end

  # @param ids [Array<String>] the layers to fetch documents for
  def self.fetch(ids, http: HttpClient.new, log: $stdout)
    documents = {}
    ids.each do |id|
      url = "#{URL}#{URI.encode_uri_component(id)}.json"
      response = http.get(url)
      next if response.is_a?(Net::HTTPNotFound)
      raise Error, "#{url} answered #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      begin
        documents[id] = JSON.parse(response.body.to_s.dup.force_encoding(Encoding::UTF_8))
      rescue JSON::ParserError
        raise Error, "#{url} answered with something other than JSON"
      end
    end
    missing = ids.size - documents.size
    raise Error, "GIBS has no layer metadata for #{missing} of #{ids.size} layers" if missing > ids.size * MAX_MISSING

    log.puts "Layer metadata: #{documents.size} of #{ids.size} layers"
    new(documents)
  end

  def self.load(dir)
    new(Snapshot.read(dir, FILE).to_h { |row| [row['id'], row['metadata']] })
  end

  attr_reader :documents

  def initialize(documents)
    @documents = documents
  end

  def save(dir)
    Snapshot.write(dir, FILE, documents.sort.map { |id, metadata| { 'id' => id, 'metadata' => metadata } })
  end

  def [](id)
    documents[id]
  end

  # Every CMR collection any layer links to
  def concept_ids
    documents.values.flat_map { |metadata| (metadata['conceptIds'] || []).map { |concept| concept['value'] } }
             .compact.uniq.sort
  end
end
