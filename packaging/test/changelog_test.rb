require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require_relative "../changelog"

class ChangelogTest < Minitest::Test
  SCRIPT = File.expand_path("../changelog.rb", __dir__)

  CHANGELOG = <<~MARKDOWN
    # Changelog

    Don't edit this file in a pull request.

    ## [Unreleased]

    - Legacy note from an older branch,
      wrapped onto a second line.

    ## [2.6.2] - 2026-10-30

    - Older work.
  MARKDOWN

  FRAGMENT = <<~MARKDOWN
    ### Changes

    <!-- One bullet per user-facing change. -->
    - Export now keeps
      your clip names.
  MARKDOWN

  def test_roll_writes_legacy_notes_then_fragments_into_one_dated_section
    rolled = Changelog.roll(
      CHANGELOG,
      [["changelog.d/a.md", FRAGMENT], ["changelog.d/b.md", "- Faster waveform.\n"]],
      "2.7.0",
      "2026-11-07"
    )

    assert_equal <<~MARKDOWN, rolled
      # Changelog

      Don't edit this file in a pull request.

      ## [Unreleased]

      #{Changelog::UNRELEASED_COMMENT}

      ## [2.7.0] - 2026-11-07

      - Legacy note from an older branch,
        wrapped onto a second line.
      - Export now keeps
        your clip names.
      - Faster waveform.

      ## [2.6.2] - 2026-10-30

      - Older work.
    MARKDOWN
  end

  def test_a_rolled_changelog_rolls_again_from_fragments_alone
    once = Changelog.roll(CHANGELOG, [["a.md", FRAGMENT]], "2.7.0", "2026-11-07")

    twice = Changelog.roll(once, [["b.md", "- Next.\n"]], "2.8.0", "2026-11-14")

    assert_includes twice, "## [Unreleased]\n\n#{Changelog::UNRELEASED_COMMENT}\n\n## [2.8.0] - 2026-11-14\n\n- Next.\n\n## [2.7.0]"
  end

  def test_rejects_an_unknown_heading_naming_file_and_line
    error = assert_raises(Changelog::Error) do
      Changelog.roll(CHANGELOG, [["changelog.d/a.md", "### Changes\n- Fine.\n### Ops\n"]], "2.7.0", "2026-11-07")
    end

    assert_match(%r{\Achangelog.d/a.md:3: unexpected heading}, error.message)
  end

  def test_rejects_prose_naming_file_and_line
    error = assert_raises(Changelog::Error) do
      Changelog.roll(CHANGELOG, [["changelog.d/a.md", "- Fine.\n\nJust some prose.\n"]], "2.7.0", "2026-11-07")
    end

    assert_match(%r{\Achangelog.d/a.md:3: expected a "- " bullet}, error.message)
  end

  def test_rejects_an_indented_line_after_a_blank_line
    error = assert_raises(Changelog::Error) do
      Changelog.roll(CHANGELOG, [["a.md", "- Fine.\n\n  stray continuation\n"]], "2.7.0", "2026-11-07")
    end

    assert_match(/\Aa.md:3:/, error.message)
  end

  def test_rejects_visible_text_between_comments
    error = assert_raises(Changelog::Error) do
      Changelog.roll(CHANGELOG, [["a.md", "- Fine.\n<!-- a --> Hidden note. <!-- b -->\n"]], "2.7.0", "2026-11-07")
    end

    assert_match(/\Aa.md:2:/, error.message)
  end

  def test_rejects_an_indented_heading_after_a_bullet
    error = assert_raises(Changelog::Error) do
      Changelog.roll(CHANGELOG, [["a.md", "- Fine.\n  ### Ops\n"]], "2.7.0", "2026-11-07")
    end

    assert_match(/\Aa.md:2: unexpected heading/, error.message)
  end

  def test_rejects_a_non_version_level_two_heading_under_unreleased
    changelog = CHANGELOG.sub("## [2.6.2]", "## Changes\n\n- Stranded note.\n\n## [2.6.2]")

    error = assert_raises(Changelog::Error) do
      Changelog.roll(changelog, [], "2.7.0", "2026-11-07")
    end

    assert_match(/\ACHANGELOG.md:10: unexpected heading "## Changes"/, error.message)
  end

  def test_rejects_an_empty_bullet
    error = assert_raises(Changelog::Error) do
      Changelog.roll(CHANGELOG, [["a.md", "- \n"]], "2.7.0", "2026-11-07")
    end

    assert_match(/\Aa.md:1:/, error.message)
  end

  def test_rejects_a_fragment_with_no_bullets
    error = assert_raises(Changelog::Error) do
      Changelog.roll(CHANGELOG, [["a.md", "### Changes\n<!-- nothing yet -->\n"]], "2.7.0", "2026-11-07")
    end

    assert_match(/\Aa.md: has no "- " bullets/, error.message)
  end

  def test_rejects_malformed_legacy_unreleased_lines_by_changelog_line
    changelog = CHANGELOG.sub("- Legacy note", "Legacy prose\n- Legacy note")

    error = assert_raises(Changelog::Error) do
      Changelog.roll(changelog, [], "2.7.0", "2026-11-07")
    end

    assert_match(/\ACHANGELOG.md:7: expected a "- " bullet/, error.message)
  end

  def test_rejects_a_version_that_already_has_a_section
    error = assert_raises(Changelog::Error) do
      Changelog.roll(CHANGELOG, [["a.md", FRAGMENT]], "2.6.2", "2026-11-07")
    end

    assert_match(/already has a section for 2.6.2/, error.message)
  end

  def test_rejects_a_missing_version
    error = assert_raises(Changelog::Error) do
      Changelog.roll(CHANGELOG, [["a.md", FRAGMENT]], nil, "2026-11-07")
    end

    assert_match(/semantic version/, error.message)
  end

  def test_rejects_a_release_with_no_notes
    changelog = CHANGELOG.sub("- Legacy note from an older branch,\n  wrapped onto a second line.\n", "")

    error = assert_raises(Changelog::Error) do
      Changelog.roll(changelog, [], "2.7.0", "2026-11-07")
    end

    assert_match(/no release notes/, error.message)
  end

  def test_rejects_a_changelog_without_an_unreleased_heading
    error = assert_raises(Changelog::Error) do
      Changelog.roll("# Changelog\n", [["a.md", FRAGMENT]], "2.7.0", "2026-11-07")
    end

    assert_match(/no ## \[Unreleased\] heading/, error.message)
  end

  def test_roll_files_deletes_exactly_the_fragments_it_read
    in_repo do |changelog, directory|
      File.write(File.join(directory, "b.md"), "- Second.\n")
      File.write(File.join(directory, "a.md"), "- First.\n")

      paths = Changelog.roll_files(changelog, directory, "2.7.0", "2026-11-07")

      assert_equal [File.join(directory, "a.md"), File.join(directory, "b.md")], paths
      assert_equal ["README.md"], Dir.children(directory)
      assert_includes File.read(changelog), "\n- Legacy note from an older branch,\n  wrapped onto a second line.\n- First.\n- Second.\n"
    end
  end

  def test_roll_files_changes_nothing_when_a_fragment_is_malformed
    in_repo do |changelog, directory|
      File.write(File.join(directory, "a.md"), "- Fine.\n")
      File.write(File.join(directory, "b.md"), "Not a bullet.\n")

      assert_raises(Changelog::Error) do
        Changelog.roll_files(changelog, directory, "2.7.0", "2026-11-07")
      end

      assert_equal CHANGELOG, File.read(changelog)
      assert_equal ["README.md", "a.md", "b.md"], Dir.children(directory).sort
    end
  end

  def test_roll_files_rejects_a_non_markdown_file
    in_repo do |changelog, directory|
      File.write(File.join(directory, "note.txt"), "- Fine.\n")

      error = assert_raises(Changelog::Error) do
        Changelog.roll_files(changelog, directory, "2.7.0", "2026-11-07")
      end

      assert_match(/note.txt: not a .md fragment/, error.message)
      assert_equal CHANGELOG, File.read(changelog)
    end
  end

  def test_cli_rolls_and_reports_failures
    in_repo do |changelog, directory|
      File.write(File.join(directory, "a.md"), FRAGMENT)

      _stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCRIPT, "roll", changelog, directory, "2.6.2")
      refute status.success?
      assert_match(/error: changelog already has a section for 2.6.2/, stderr)

      _stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCRIPT, "roll", changelog, directory, "2.7.0")
      assert status.success?, stderr
      assert_match(/^## \[2.7.0\] - \d{4}-\d{2}-\d{2}$/, File.read(changelog))
      assert_equal ["README.md"], Dir.children(directory)
    end
  end

  private

  def in_repo
    Dir.mktmpdir do |root|
      changelog = File.join(root, "CHANGELOG.md")
      directory = File.join(root, "changelog.d")
      File.write(changelog, CHANGELOG)
      Dir.mkdir(directory)
      File.write(File.join(directory, "README.md"), "# Not a fragment\n\nProse.\n")
      yield changelog, directory
    end
  end
end
