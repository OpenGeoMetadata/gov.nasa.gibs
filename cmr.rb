require 'json'
require 'uri'
require_relative 'http_client'
require_relative 'snapshot'

# The CMR collections GIBS's layers are made from: their titles, DOIs, citations, platforms, keywords, extents and
# use constraints, from NASA's Common Metadata Repository.
class Cmr
  URL = 'https://cmr.earthdata.nasa.gov/search/collections.umm_json'
  FILE = 'collections.jsonl'

  # Concept IDs asked about per request, which keeps the query string to a few kilobytes
  BATCH = 100

  # The fields a collection keeps. CMR revises collections often, mostly in fields the records don't use.
  FIELDS = %w[EntryTitle ShortName Version DOI Abstract CollectionCitations DataCenters Platforms ScienceKeywords
              SpatialExtent UseConstraints].freeze

  # GIBS links some collections that CMR no longer has (about a fifth of them in October 2026). Finding fewer than
  # half means CMR answered badly, and the run stops rather than drop the DOIs from hundreds of records.
  MIN_FOUND = 0.5

  class Error < StandardError; end

  def self.fetch(concept_ids, http: HttpClient.new, log: $stdout)
    collections = {}
    concept_ids.each_slice(BATCH) do |batch|
      query = URI.encode_www_form(batch.map { |id| ['concept_id[]', id] } + [['page_size', BATCH]])
      response = http.get("#{URL}?#{query}")
      raise Error, "CMR answered #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body.to_s.dup.force_encoding(Encoding::UTF_8)).fetch('items').each do |item|
        collections[item.dig('meta', 'concept-id')] = item['umm'].slice(*FIELDS)
      end
    rescue JSON::ParserError, KeyError
      raise Error, 'CMR answered with something other than a list of collections'
    end
    if concept_ids.any? && collections.size < concept_ids.size * MIN_FOUND
      raise Error, "CMR has only #{collections.size} of the #{concept_ids.size} collections GIBS links"
    end

    log.puts "CMR: #{collections.size} of the #{concept_ids.size} collections GIBS links"
    new(collections)
  end

  def self.load(dir)
    new(Snapshot.read(dir, FILE).to_h { |row| [row['concept_id'], row['umm']] })
  end

  attr_reader :collections

  def initialize(collections)
    @collections = collections
  end

  def save(dir)
    Snapshot.write(dir, FILE, collections.sort.map { |id, umm| { 'concept_id' => id, 'umm' => umm } })
  end

  def [](concept_id)
    collections[concept_id]
  end
end
