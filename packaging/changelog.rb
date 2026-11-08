#!/usr/bin/env ruby
# Roll release notes into CHANGELOG.md at release time.
#   packaging/changelog.rb roll <changelog> <fragments_dir> <version>
# Pull requests add one small file to changelog.d/ instead of editing CHANGELOG.md
# (see changelog.d/README.md). Rolling reads any bullets still under
# ## [Unreleased], then every fragment in filename order, writes them as one dated
# version section, and deletes exactly the fragments it read. Parsing is strict and
# nothing is written unless every note parses.

require "date"
require "tempfile"

module Changelog
  class Error < StandardError; end

  VERSION = /\A\d+\.\d+\.\d+\z/
  COMMENT = /\A<!--((?!-->).)*-->\z/
  UNRELEASED_HEADING = "## [Unreleased]"
  UNRELEASED_COMMENT =
    "<!-- Don't add notes here. Add a file to changelog.d/ instead (see changelog.d/README.md). -->"
  SECTION_HEADING = "### Changes"
  README = "README.md"
  USAGE = <<~USAGE.strip
    usage:
      changelog.rb roll <changelog> <fragments_dir> <version>
      changelog.rb validate <fragments_dir>
  USAGE

  # Returns the bullets in `lines` (each an array of output lines). `first_line`
  # is the 1-based line number of lines[0] in `source`, for error messages.
  def self.parse_notes(lines, source, first_line = 1)
    bullets = []
    open_bullet = nil
    lines.each_with_index do |raw, index|
      line = raw.rstrip
      location = "#{source}:#{first_line + index}"
      if line.empty?
        open_bullet = nil
      elsif COMMENT.match?(line)
        open_bullet = nil
      elsif line == SECTION_HEADING
        open_bullet = nil
      elsif line.lstrip.start_with?("#")
        raise Error, "#{location}: unexpected heading #{line.inspect} (only #{SECTION_HEADING.inspect} is allowed)"
      elsif line.start_with?("- ") && !line[2..-1].strip.empty?
        open_bullet = ["- #{line[2..-1].strip}"]
        bullets << open_bullet
      elsif line.match?(/\A\s/) && open_bullet
        open_bullet << "  #{line.strip}"
      else
        raise Error, "#{location}: expected a \"- \" bullet, an indented continuation of one, " \
          "a #{SECTION_HEADING.inspect} heading, or a <!-- --> comment, got #{line.inspect}"
      end
    end
    bullets
  end

  def self.parse_fragment(text, source)
    bullets = parse_notes(text.lines, source)
    raise Error, "#{source}: has no \"- \" bullets" if bullets.empty?

    bullets
  end

  # Returns the new CHANGELOG text. `fragments` is an ordered list of
  # [source, text] pairs.
  def self.roll(changelog, fragments, version, date)
    raise Error, "version must be semantic version X.Y.Z, got #{version.inspect}" unless VERSION.match?(version.to_s)

    lines = changelog.lines
    headings = lines.each_index.select { |index| lines[index].rstrip == UNRELEASED_HEADING }
    raise Error, "changelog has no #{UNRELEASED_HEADING} heading" if headings.empty?
    raise Error, "changelog has more than one #{UNRELEASED_HEADING} heading" if headings.length > 1
    if lines.any? { |line| line.start_with?("## [#{version}]") }
      raise Error, "changelog already has a section for #{version}"
    end

    start = headings.first + 1
    finish = (start...lines.length).find { |index| lines[index].start_with?("## [") } || lines.length
    bullets = parse_notes(lines[start...finish], "CHANGELOG.md", start + 1)
    fragments.each { |source, text| bullets.concat(parse_fragment(text, source)) }
    raise Error, "no release notes: add a file to changelog.d/ (see changelog.d/README.md)" if bullets.empty?

    rolled = <<~MARKDOWN
      #{UNRELEASED_HEADING}

      #{UNRELEASED_COMMENT}

      ## [#{version}] - #{date}

      #{bullets.flatten.join("\n")}

    MARKDOWN
    lines[0...headings.first].join + rolled + lines[finish..-1].join
  end

  def self.fragment_paths(directory)
    raise Error, "#{directory} is not a directory" unless File.directory?(directory)

    Dir.children(directory).sort.reject { |name| name == README }.map do |name|
      path = File.join(directory, name)
      raise Error, "#{path}: not a .md fragment file" unless name.end_with?(".md") && File.file?(path)

      path
    end
  end

  def self.roll_files(changelog_path, directory, version, date)
    paths = fragment_paths(directory)
    fragments = paths.map { |path| [path, File.read(path)] }
    rolled = roll(File.read(changelog_path), fragments, version, date)
    replace_file(changelog_path, rolled)
    paths.each { |path| File.delete(path) }
    paths
  end

  # Parses every checked-in fragment without changing the changelog or fragments.
  def self.validate_fragments(directory)
    paths = fragment_paths(directory)
    paths.each { |path| parse_fragment(File.read(path), path) }
    paths
  end

  def self.replace_file(path, contents)
    Tempfile.create(["changelog-", ".md"], File.dirname(path)) do |file|
      file.write(contents)
      file.flush
      file.fsync
      temporary_path = file.path
      file.close
      File.chmod(File.stat(path).mode, temporary_path)
      File.rename(temporary_path, path)
    end
  end
  private_class_method :replace_file

  def self.run_cli(arguments)
    command = arguments.shift
    case command
    when "roll"
      raise Error, USAGE unless arguments.length == 3

      changelog_path, directory, version = arguments
      date = Date.today.iso8601
      paths = roll_files(changelog_path, directory, version, date)
      puts "Rolled #{paths.length} changelog.d fragment(s) into [#{version}] - #{date}"
    when "validate"
      raise Error, USAGE unless arguments.length == 1

      paths = validate_fragments(arguments.first)
      puts "Validated #{paths.length} changelog.d fragment(s)"
    else
      raise Error, USAGE
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    Changelog.run_cli(ARGV.dup)
  rescue Changelog::Error, SystemCallError => error
    warn "error: #{error.message}"
    exit 1
  end
end
