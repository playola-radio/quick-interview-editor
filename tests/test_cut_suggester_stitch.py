"""Stage-1 stitching of overlapping-window partitions into one clean cover."""

from cut_suggester.models import TopicPartition
from cut_suggester.stitch import stitch_partitions


def test_single_window_is_preserved_with_labels():
    window = [TopicPartition(0, 1, "a"), TopicPartition(2, 4, "b")]
    out = stitch_partitions([window], n=5)
    assert [(p.start, p.end) for p in out] == [(0, 1), (2, 4)]
    assert [p.label for p in out] == ["a", "b"]


def test_full_coverage_with_no_gaps_or_overlaps():
    window = [TopicPartition(0, 2, "a"), TopicPartition(3, 5, "b")]
    out = stitch_partitions([window], n=6)
    covered = []
    for p in out:
        covered.extend(range(p.start, p.end + 1))
    assert covered == list(range(6))


def test_overlapping_windows_agreeing_on_a_boundary_dedupe():
    w1 = [TopicPartition(0, 1, "a"), TopicPartition(2, 3, "b")]
    w2 = [TopicPartition(2, 3, "b2"), TopicPartition(4, 5, "c")]
    out = stitch_partitions([w1, w2], n=6)
    assert [(p.start, p.end) for p in out] == [(0, 1), (2, 3), (4, 5)]


def test_seam_artifact_boundary_is_not_introduced():
    # w2 is forced to start at 2, but that seam is not a real topic boundary
    # (neither window votes an interior boundary there), so no cut appears at 2.
    w1 = [TopicPartition(0, 3, "whole")]
    w2 = [TopicPartition(2, 5, "whole")]
    out = stitch_partitions([w1, w2], n=6)
    assert [(p.start, p.end) for p in out] == [(0, 5)]


def test_three_transitively_nearby_votes_collapse_to_one_boundary():
    # Votes 5,6,7 (each within tolerance of the previous) are ONE fuzzy boundary,
    # not two — the cluster must grow transitively.
    w1 = [TopicPartition(0, 4, "a"), TopicPartition(5, 9, "b")]  # vote 5
    w2 = [TopicPartition(0, 5, "a"), TopicPartition(6, 9, "b")]  # vote 6
    w3 = [TopicPartition(0, 6, "a"), TopicPartition(7, 9, "b")]  # vote 7
    out = stitch_partitions([w1, w2, w3], n=10, boundary_tolerance=1)
    assert len(out) == 2


def test_nearby_boundary_votes_are_merged_within_tolerance():
    # Two windows vote a boundary one sentence apart; they collapse to one cut.
    w1 = [TopicPartition(0, 2, "a"), TopicPartition(3, 5, "b")]
    w2 = [TopicPartition(0, 3, "a"), TopicPartition(4, 5, "b")]
    out = stitch_partitions([w1, w2], n=6, boundary_tolerance=1)
    assert len(out) == 2  # one merged boundary, not two adjacent cuts
