#!/usr/bin/env ruby

require "fileutils"
require "rexml/document"
require "tempfile"

module ReleaseNotes
  class Error < StandardError; end

  VERSION = /\A\d+\.\d+\.\d+\z/
  RELEASE_HEADING = /\A## \[(\d+\.\d+\.\d+)\] - \d{4}-\d{2}-\d{2}\s*\z/
  USAGE = <<~TEXT.freeze
    usage:
      release_notes.rb extract <changelog> <version> <output>
      release_notes.rb backfill <appcast> <changelog> <version>
  TEXT

  def self.extract(changelog, version)
    raise Error, "version must be semantic version X.Y.Z" unless VERSION.match?(version)

    lines = changelog.lines
    matches = []
    lines.each_index do |index|
      heading = RELEASE_HEADING.match(lines[index])
      next unless heading && heading[1] == version

      boundary = ((index + 1)...lines.length).find do |candidate|
        lines[candidate].start_with?("## ")
      end || lines.length
      matches << lines[(index + 1)...boundary].join.strip
    end

    raise Error, "release #{version} is missing from the changelog" if matches.empty?
    raise Error, "release #{version} appears more than once in the changelog" if matches.length > 1
    raise Error, "release #{version} has no notes" if matches.first.empty?

    matches.first
  end

  def self.set_description(item, notes)
    raise Error, "release notes are empty" if notes.strip.empty?

    descriptions = item.elements.to_a("description")
    description = descriptions.shift || item.add_element("description")
    descriptions.each { |duplicate| item.delete(duplicate) }
    description.children.to_a.each { |child| description.delete(child) }
    description.add_attribute("sparkle:format", "markdown")
    description.add_text(notes)
    description
  end

  def self.backfill_appcast(appcast, version, notes)
    raise Error, "version must be semantic version X.Y.Z" unless VERSION.match?(version)

    document = REXML::Document.new(appcast)
    channel = document.elements["rss/channel"]
    raise Error, "appcast has no rss/channel" unless channel

    matches = channel.elements.to_a("item").select do |item|
      item.elements["sparkle:shortVersionString"]&.text&.strip == version
    end
    raise Error, "appcast item #{version} is missing" if matches.empty?
    raise Error, "appcast item #{version} appears more than once" if matches.length > 1

    set_description(matches.first, notes)
    output = String.new
    document.write(output)
    validate_backfill(output, version, notes)
    output
  rescue REXML::ParseException => error
    raise Error, "appcast is not valid XML: #{error.message}"
  end

  def self.validate_backfill(appcast, version, notes)
    document = REXML::Document.new(appcast)
    matches = document.elements.to_a("rss/channel/item").select do |item|
      item.elements["sparkle:shortVersionString"]&.text&.strip == version
    end
    raise Error, "updated appcast item #{version} is not unique" unless matches.length == 1

    description = matches.first.elements["description"]
    raise Error, "updated appcast item #{version} has no description" unless description
    unless description.attribute("sparkle:format")&.value == "markdown"
      raise Error, "updated appcast item #{version} description is not markdown"
    end
    unless description.text == notes
      raise Error, "updated appcast item #{version} notes changed during XML serialization"
    end
  end
  private_class_method :validate_backfill

  def self.run_cli(arguments)
    command = arguments.shift
    case command
    when "extract"
      raise Error, USAGE unless arguments.length == 3

      changelog_path, version, output_path = arguments
      notes = extract(File.read(changelog_path), version)
      FileUtils.mkdir_p(File.dirname(output_path))
      File.write(output_path, "#{notes}\n")
    when "backfill"
      raise Error, USAGE unless arguments.length == 3

      appcast_path, changelog_path, version = arguments
      notes = extract(File.read(changelog_path), version)
      output = backfill_appcast(File.read(appcast_path), version, notes)
      replace_file(appcast_path, output)
    else
      raise Error, USAGE
    end
  end

  def self.replace_file(path, contents)
    Tempfile.create(["appcast-", ".xml"], File.dirname(path)) do |file|
      file.write(contents)
      file.flush
      file.fsync
      temporary_path = file.path
      file.close
      File.rename(temporary_path, path)
    end
  end
  private_class_method :replace_file
end

if $PROGRAM_NAME == __FILE__
  begin
    ReleaseNotes.run_cli(ARGV.dup)
  rescue ReleaseNotes::Error, SystemCallError => error
    warn "error: #{error.message}"
    exit 1
  end
end
