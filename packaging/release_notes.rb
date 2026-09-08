#!/usr/bin/env ruby

module ReleaseNotes
  class Error < StandardError; end

  VERSION = /\A\d+\.\d+\.\d+\z/
  RELEASE_HEADING = /\A## \[(\d+\.\d+\.\d+)\] - \d{4}-\d{2}-\d{2}\s*\z/

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
end
