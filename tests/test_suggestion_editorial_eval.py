"""Metric correctness and offline orchestration, not live model quality."""

import pytest


def prediction(kind, start, end):
    return dict(product_type=kind, start_index=start, end_index=end)


def positive(kind, start, end):
    return dict(type=kind, start=start, end=end)


def test_merged_prediction_can_match_only_one_distinct_take():
    from evals.cut_suggestions.editorial_runner import editorial_metrics
    labels = dict(positives=[positive('image-id', 4, 5), positive('image-id', 6, 7)], negativeSpans=[])
    result = editorial_metrics([prediction('image-id', 4, 7)], labels)
    assert result['positive_take_recall'] == .5
    assert result['matched'] == 1
    assert result['exact_span_matches'] == 0


def test_matching_is_maximum_not_greedy_and_deterministic():
    from evals.cut_suggestions.editorial_runner import editorial_metrics
    labels = dict(positives=[positive('intro', 0, 1), positive('intro', 2, 3)], negativeSpans=[])
    predicted = [prediction('intro', 0, 3), prediction('intro', 0, 1)]
    result = editorial_metrics(predicted, labels)
    assert result['matched'] == 2
    assert result == editorial_metrics(predicted, labels)
    assert len(result['unexpected_overlaps']) == 1


def test_negative_singleton_flags_broad_intro_and_nested_expected_overlap_is_allowed():
    from evals.cut_suggestions.editorial_runner import editorial_metrics
    labels = dict(positives=[positive('image-promo', 8, 22), positive('image-id', 15, 16),
                            positive('intro', 24, 25), positive('image-post-commercial', 23, 23)],
                  negativeSpans=[dict(start=26, end=26, forbiddenTypes=['intro'])])
    predicted = [prediction('image-promo', 8, 22), prediction('image-id', 15, 16),
                 prediction('intro', 23, 28), prediction('image-post-commercial', 23, 23)]
    result = editorial_metrics(predicted, labels)
    assert result['matched'] == 4
    assert len(result['negative_span_matches']) == 1
    assert result['negative_span_matches'][0]['prediction'] == 2
    assert len(result['unexpected_overlaps']) == 1
    assert result['unexpected_overlaps'][0]['types'] == ['intro', 'image-post-commercial']


def test_cached_mode_fails_closed_without_constructing_live_client(tmp_path, monkeypatch):
    from cut_suggester.cache import CacheMiss
    from evals.cut_suggestions import editorial_runner
    def forbidden(*args):
        pytest.fail('cached evaluation must not construct a live provider')
    monkeypatch.setattr(editorial_runner, 'live_client_for', forbidden)
    with pytest.raises(CacheMiss):
        editorial_runner.run_editorial_eval(cache_dir=tmp_path / 'cache', output_dir=tmp_path / 'run')


def test_request_is_stable_and_versions_create_independent_run_identity():
    from evals.cut_suggestions.editorial_runner import build_request
    from cut_suggester.configured_run import request_identity
    first = build_request()
    assert first == build_request()
    assert first['options']['discovery_prompt_version'] == 'configured-v2'
    old = build_request(discovery_version='v2')
    assert old['run_id'] == '2bbc3c68-9ad1-5bc9-9ab8-b50200dc10d3'
    assert first['run_id'] != old['run_id']
    assert request_identity(first) != request_identity(old)


def test_committed_actual_gpt4o_responses_pass_exact_synthetic_gate_offline():
    from evals.cut_suggestions.editorial_runner import run_editorial_eval
    report = run_editorial_eval()
    assert report['quality_pass']
    assert report['metrics']['exact_span_matches'] == report['metrics']['matched'] == 9
    intros = [c for c in report['result']['suggestions'] if c['product_type'] == 'intro']
    assert [(c['start_index'], c['end_index'], c['duration_sec'], c['fields']) for c in intros] == [
        (0, 3, 8.0, {'artist-name': 'River Vale', 'song-title': 'Paper Lanterns'}),
        (24, 25, 4.0, {'artist-name': 'Nova Reed', 'song-title': 'Harbor Lights'}),
    ]
