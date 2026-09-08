"""Prompt contracts and scripted-provider routing, not measured model accuracy."""
import hashlib

import pytest

from cut_suggester.configured_discovery import _prompt
from cut_suggester.extraction import plan_extraction_batches
from cut_suggester.suggestion_config import split_discovery_types
from test_configured_discovery import _sentences
from test_interview_artist import ArtistProvider, artist_request, run, spotlight_title
from test_suggestion_extraction import _fields, _sentences as extraction_sentences, _type


@pytest.mark.parametrize('version,expected', [
    ('configured-v1', '414e6af206e499214d53f7267ceb4cb3cb7acecd7b4671859a1f7e5019c8ac61'),
    ('configured-v2', '6bb90900c78ac344f01ff686a21fd617d9a4e535baf4fc21eaebd2a1798abdf7'),
    ('configured-v3', '9ac7a52aac227a07387664e632d2c82fcd36df420128e9bc764399521b27e8d7'),
    ('configured-v4', '9ac7a52aac227a07387664e632d2c82fcd36df420128e9bc764399521b27e8d7'),
])
def test_historical_discovery_prompt_bytes(version, expected):
    prompt = _prompt(_sentences(), {'intro': 'Useful commentary.', 'image-id': 'Complete IDs.',
                                   'custom-voice': 'URLs required.'}, 110, 219,
                     discovery_prompt_version=version)
    assert hashlib.sha256(prompt.encode()).hexdigest() == expected


def extraction_plan(version='fields-v3', **kwargs):
    return plan_extraction_batches(
        [{'candidate_id': 'c1', 'product_type': 'intro', 'start_index': 2, 'end_index': 2}],
        [_type()], _fields(), extraction_sentences(), speaker_ids={102: 'River Vale'},
        interview_artist='River Vale', extraction_prompt_version=version, **kwargs)


@pytest.mark.parametrize('version,expected', [
    ('fields-v1', '2e9cf0a5c4e654393ace2aea0ceaf366718da9e4c0d67f69160263c8d4502fe2'),
    ('fields-v2', '773322f10025a8f421b75a1fc69cc27754963a89f5776ad9278e717a27806b20'),
])
def test_historical_extraction_prompt_bytes(version, expected):
    assert hashlib.sha256(extraction_plan(version).batches[0].prompt.encode()).hexdigest() == expected


def test_v5_routes_intro_to_configured_discovery_and_requires_one_main_subject():
    req = artist_request()
    tuned, configured = split_discovery_types(req['configuration'], discovery_prompt_version='configured-v5')
    assert [t['id'] for t in tuned] == ['spotlight']
    assert [t['id'] for t in configured] == ['intro']
    prompt = _prompt(_sentences(), {'intro': 'Useful commentary.'}, 0, 3,
                     discovery_prompt_version='configured-v5')
    for instruction in ('one specific artist or one specific song', 'entire clip',
                        'naturally expect', 'general discussion', 'incidental examples',
                        'roundups', 'coequal', 'secondary comparison', 'Do not count names',
                        'No immediate musical handoff', 'Each independently complete performance'):
        assert instruction.lower() in prompt.lower()
    assert 'configured guidelines' in prompt


@pytest.mark.parametrize('types', [
    {'custom-intro': 'Allow roundups.'},
    {'image-id': 'Complete IDs.', 'image-promo': 'Full promos.'},
])
def test_v5_without_builtin_intro_preserves_previous_prompt(types):
    assert _prompt(_sentences(), types, 0, 3, discovery_prompt_version='configured-v5') == _prompt(
        _sentences(), types, 0, 3, discovery_prompt_version='configured-v4')


def test_v3_extraction_scopes_single_subject_check_before_identity_extraction():
    prompt = extraction_plan().batches[0].prompt
    for instruction in ('type: intro', 'one specific artist or one specific song', 'entire clip',
                        'both artist-name and song-title', 'null', 'recognizable',
                        'roundups', 'coequal', 'secondary comparison', 'Do not count names',
                        'User-provided interview artist: "River Vale"', "subject's own music",
                        'Other candidate types', 'other fields', 'Never emit the literal placeholder SELF'):
        assert instruction.lower() in prompt.lower()
    assert prompt.index('one specific artist') < prompt.index('Required fields:')


def test_v3_single_subject_rule_and_type_are_counted_in_mandatory_budget():
    legacy = extraction_plan('fields-v2').batches[0]
    focused = extraction_plan().batches[0]
    assert focused.mandatory_characters > legacy.mandatory_characters
    too_small = extraction_plan(max_input_characters=focused.mandatory_characters - 1)
    assert too_small.batches == ()
    assert too_small.input_size_diagnostics[0].mandatory_characters == focused.mandatory_characters
    exact = extraction_plan(max_input_characters=focused.mandatory_characters).batches[0]
    assert exact.input_characters == exact.mandatory_characters
    assert 'type: intro' in exact.prompt and '[2] Song Nobody Wins' in exact.prompt


@pytest.mark.parametrize('type_id', ['spotlight', 'custom-intro', 'image-id'])
def test_v3_non_intro_and_custom_fields_keep_configured_instructions(type_id):
    type_definition = {**_type(), 'id': type_id}
    plan = plan_extraction_batches(
        [{'candidate_id': 'custom', 'product_type': type_id, 'start_index': 2, 'end_index': 2}],
        [type_definition], _fields(), extraction_sentences(), extraction_prompt_version='fields-v3')
    batch = plan.batches[0]
    assert f'type: {type_id}' in batch.prompt
    assert 'single-subject check' not in batch.prompt
    assert batch.expected == {'custom': {'artist-name', 'song-title'}}
    assert 'Find the recording title.' in batch.prompt


def focused_request(text, *, spotlight=True):
    req = artist_request(1, spotlight=spotlight)
    req['options'].update(discovery_prompt_version='configured-v5', extraction_prompt_version='fields-v3')
    req['interview_artist'] = 'River Vale'
    req['transcript_units'][0].update(text=text, end_sec=20, end_sample=20 * 44100)
    return req


@pytest.mark.parametrize('text,values,expected', [
    ('The industry changed for River Vale, Nova Reed, and Cedar Lane. Streaming transformed everyone.',
     {}, 'spotlight'),
    ('River Vale uses silence, while Nova Reed uses big choruses. Both approaches work equally well.',
     {}, 'spotlight'),
    ('River Vale has transformed songwriting. Her unusual phrasing makes the melody intimate.',
     {'artist-name': 'River Vale'}, 'intro'),
    ('I wrote Paper Lanterns after losing my home. The rising melody carries the hope I found.',
     {'song-title': 'Paper Lanterns', 'artist-name': 'River Vale'}, 'intro'),
    ('River Vale has transformed songwriting. Unlike Nova Reed, her phrasing leaves room for silence; '
     'that restraint defines River Vale’s music.', {'artist-name': 'River Vale'}, 'intro'),
])
def test_v5_scripted_subject_decisions_route_and_replay_without_paid_calls(tmp_path, text, values, expected):
    req = focused_request(text)
    spotlight_title(req)
    provider = ArtistProvider(intros=[(0, 0)], values={**values, 'descriptive-title': 'Music discussion'})
    result = run(req, provider, tmp_path)
    assert result['status'] == 'ready'
    assert [c['product_type'] for c in result['suggestions']] == [expected]
    assert any(stage == 'configured-discovery' for stage, _ in provider.calls)
    extraction = next(prompt for stage, prompt in provider.calls if stage.startswith('extract:'))
    assert 'type: intro' in extraction
    if expected == 'spotlight':
        assert result['suggestions'][0]['fields'] == {'descriptive-title': 'Music discussion'}
        assert provider.extractions == 2
    else:
        assert result['suggestions'][0]['fields']['artist-name'] == values.get('artist-name')
    req['mode'] = 'resume'
    retry = ArtistProvider()
    assert run(req, retry, tmp_path)['suggestions'] == result['suggestions']
    assert retry.calls == []


def test_v5_extraction_failure_is_not_a_single_subject_rejection(tmp_path):
    req = focused_request('River Vale and Nova Reed changed the industry.')
    first = run(req, ArtistProvider(intros=[(0, 0)], fail=[1]), tmp_path)
    assert first['status'] == 'needs_retry'
    assert [c['product_type'] for c in first['suggestions']] == ['intro']
    retry = ArtistProvider()
    final = run(req, retry, tmp_path)
    assert final['status'] == 'ready'
    assert [c['product_type'] for c in final['suggestions']] == ['spotlight']
    assert len(retry.calls) == 1


def test_v3_mixed_batch_labels_types_and_keeps_custom_field_contracts():
    types = [_type(), {'id': 'custom-intro', 'template': [{'kind': 'field', 'value': 'descriptive-title'}],
                       'sequenceFieldIDs': []}]
    batch = plan_extraction_batches([
        {'candidate_id': 'intro', 'product_type': 'intro', 'start_index': 2, 'end_index': 2},
        {'candidate_id': 'custom', 'product_type': 'custom-intro', 'start_index': 3, 'end_index': 3},
    ], types, _fields(), extraction_sentences(), extraction_prompt_version='fields-v3').batches[0]
    assert batch.expected == {'intro': {'artist-name', 'song-title'}, 'custom': {'descriptive-title'}}
    assert 'For candidates with type intro only' in batch.prompt
    assert 'Other candidate types and all other fields' in batch.prompt
    assert 'Candidate intro (required evidence):\nCandidate type: intro\n[2]' in batch.prompt
    assert 'Candidate custom (required evidence):\nCandidate type: custom-intro\n[3]' in batch.prompt
    assert '- descriptive-title: Do not use this unless requested.' in batch.prompt
