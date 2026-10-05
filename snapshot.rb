require 'fileutils'
require 'json'
require 'zlib'

# A run's snapshot: what it fetched, gzipped in tmp/, so that a run can be repeated or debugged without fetching
# everything again. Plain files work too, which is what the tests use. Adapted from gov.usgs.tnm's, with text
# files beside the JSON lines for the capabilities documents, which are kept as GIBS sent them.
module Snapshot
  class Error < StandardError; end

  def self.write(dir, name, rows)
    write_text(dir, name, rows.map { |row| "#{JSON.generate(row)}\n" }.join)
  end

  def self.read(dir, name)
    read_text(dir, name).each_line.reject { |line| line.strip.empty? }.map { |line| JSON.parse(line) }
  end

  def self.write_text(dir, name, text)
    FileUtils.mkdir_p(dir)
    Zlib::GzipWriter.open(File.join(dir, "#{name}.gz")) { |gzip| gzip.write(text) }
  end

  # Read as UTF-8 whatever the locale: descriptions carry degree signs and curly quotes
  def self.read_text(dir, name)
    gzipped = File.join(dir, "#{name}.gz")
    plain = File.join(dir, name)
    if File.exist?(gzipped)
      Zlib::GzipReader.open(gzipped) { |gzip| gzip.read.force_encoding(Encoding::UTF_8) }
    elsif File.exist?(plain)
      File.read(plain, mode: 'r:bom|utf-8')
    else
      raise Error, "No #{name} in the snapshot at #{dir}"
    end
  end
end
