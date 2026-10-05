require 'json'
require_relative 'capabilities'
require_relative 'http_client'
require_relative 'snapshot'

# When a layer's time dimension began, for the layers whose capabilities list only their latest 100 periods: GOES,
# Himawari and TEMPO, whose observations come every 10 minutes to an hour. Their DescribeDomains documents list
# every period.
class Domains
  FILE = 'domains.jsonl'

  class Error < StandardError; end

  # @param entries [Hash{String => Capabilities::Entry}] the entry each layer's dates are read from
  def self.fetch(entries, http: HttpClient.new, log: $stdout)
    starts = {}
    entries.select { |_id, entry| entry.time&.truncated? }.sort.each do |id, entry|
      url = url(entry)
      next log.puts("Domains: #{id} offers no DescribeDomains document") unless url

      response = http.get(url)
      next log.puts("Domains: #{url} answered #{response.code}") unless response.is_a?(Net::HTTPSuccess)

      start = first_day(response.body.to_s)
      starts[id] = start if start
    end
    log.puts "Domains: start dates for #{starts.size} layers with truncated time dimensions"
    new(starts)
  end

  def self.load(dir)
    new(Snapshot.read(dir, FILE).to_h { |row| [row['id'], row['start']] })
  end

  # The document covering every place and period: GIBS's template for it ends in {BBOX}/all.xml
  def self.url(entry)
    template = entry.domain_templates.find { |candidate| candidate.end_with?('/{BBOX}/all.xml') }
    template&.sub('{TileMatrixSet}', entry.tile_matrix_set)&.sub('{BBOX}', 'all')
  end

  # The first day of a domain, which lists start/end/period intervals separated by commas in date order
  def self.first_day(xml)
    domain = xml[%r{<Domain>([^<]+)</Domain>}, 1]
    domain&.split(',')&.map { |interval| interval.strip.split('/').first[0, 10] }&.min
  end

  attr_reader :starts

  def initialize(starts)
    @starts = starts
  end

  def save(dir)
    Snapshot.write(dir, FILE, starts.sort.map { |id, start| { 'id' => id, 'start' => start } })
  end

  def [](id)
    starts[id]
  end
end
