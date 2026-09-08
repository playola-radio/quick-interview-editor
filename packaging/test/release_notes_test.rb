require "minitest/autorun"
require "rexml/document"
require_relative "../release_notes"

class ReleaseNotesTest < Minitest::Test
  CHANGELOG = <<~MARKDOWN
    # Changelog

    ## [Unreleased]

    - Work in progress.

    ## [2.0.0] - 2026-09-08

    - Save and reopen `.pie` projects.
    - Review suggestions before export.

    ## [1.9.0] - 2026-08-01

    - Older work.
  MARKDOWN

  def test_extracts_only_the_exact_release_body
    assert_equal <<~MARKDOWN.strip, ReleaseNotes.extract(CHANGELOG, "2.0.0")
      - Save and reopen `.pie` projects.
      - Review suggestions before export.
    MARKDOWN
  end

  def test_rejects_invalid_version
    error = assert_raises(ReleaseNotes::Error) do
      ReleaseNotes.extract(CHANGELOG, "v2.0")
    end

    assert_match(/semantic version/, error.message)
  end

  def test_rejects_missing_version
    error = assert_raises(ReleaseNotes::Error) do
      ReleaseNotes.extract(CHANGELOG, "3.0.0")
    end

    assert_match(/missing/, error.message)
  end

  def test_rejects_duplicate_version
    duplicate = <<~MARKDOWN
      ## [2.0.0] - 2026-09-08

      - First copy.

      ## [2.0.0] - 2026-09-09

      - Second copy.
    MARKDOWN

    error = assert_raises(ReleaseNotes::Error) do
      ReleaseNotes.extract(duplicate, "2.0.0")
    end

    assert_match(/more than once/, error.message)
  end

  def test_rejects_empty_release
    empty = <<~MARKDOWN
      ## [2.0.0] - 2026-09-08

      ## [1.9.0] - 2026-08-01

      - Older work.
    MARKDOWN

    error = assert_raises(ReleaseNotes::Error) do
      ReleaseNotes.extract(empty, "2.0.0")
    end

    assert_match(/no notes/, error.message)
  end

  def test_sets_a_markdown_description_that_round_trips_special_text
    document = REXML::Document.new(<<~XML)
      <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
        <channel><item><title>Version 2.0.0</title></item></channel>
      </rss>
    XML
    item = document.elements["rss/channel/item"]
    notes = "- Audio & export <work> safely.\n- A CDATA edge: ]]>"

    ReleaseNotes.set_description(item, notes)

    output = String.new
    document.write(output)
    reparsed = REXML::Document.new(output)
    description = reparsed.elements["rss/channel/item/description"]
    assert_equal "markdown", description.attribute("sparkle:format").value
    assert_equal notes, description.text
  end

  def test_replaces_an_existing_description
    document = REXML::Document.new(<<~XML)
      <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
        <channel><item><description>See the changelog.</description></item></channel>
      </rss>
    XML
    item = document.elements["rss/channel/item"]

    ReleaseNotes.set_description(item, "- The actual notes.")

    assert_equal 1, item.elements.to_a("description").length
    assert_equal "- The actual notes.", item.elements["description"].text
    assert_equal "markdown", item.elements["description"].attribute("sparkle:format").value
  end

  def test_rejects_a_blank_description
    document = REXML::Document.new("<item />")

    error = assert_raises(ReleaseNotes::Error) do
      ReleaseNotes.set_description(document.root, " \n")
    end

    assert_match(/empty/, error.message)
  end
end
