"""Scripted provider responses verify qualification, transport, and paid replay."""
import copy
import json
import re
import uuid

import pytest

from cut_suggester.configured_discovery import _candidate_id, _prompt
from cut_suggester.configured_run import immutable_request, request_identity, run_configured_suggest, validate_request
from cut_suggester.run_journal import JournalRecoveryError, JournalStorageError
from cut_suggester.transcript import sentences_from_units
from test_configured_run import BroadIntroProvider, broad_intro_request, journal
from cut_suggester.llm import LLMResponse


def artist_request(count=10, *, spotlight=True, naming=True):
    req = broad_intro_request(['I learned to leave space in the melody.'] * count,
                              include_spotlight=spotlight, fields=naming)
    req['options'].update(discovery_prompt_version='configured-v4', extraction_prompt_version='fields-v2')
    return req


class ArtistProvider(BroadIntroProvider):
    def __init__(self, intros=((0, 9),), spotlights=(), values=None, fail=()):
        super().__init__(intros, spotlights)
        self.values = values or {}
        self.fail = fail

    def complete(self, prompt, *, purpose=''):
        if purpose.startswith('extract:'):
            self.calls.append((purpose, prompt))
            self.extractions += 1
            if self.extractions in self.fail:
                raise RuntimeError('temporary failure')
            expected = re.findall(r'For candidate (.*?), return exactly these field IDs: (.*?)\.', prompt)
            return LLMResponse(json.dumps({'results': [dict(candidate_id=cid, fields=[
                dict(field_id=f, value=self.values.get(cid, self.values).get(f)) for f in fields.split(', ')
            ]) for cid, fields in expected]}))
        return super().complete(prompt, purpose=purpose)


def run(req, provider, path):
    return run_configured_suggest(req, provider, journal(path, req), lambda e: None)


@pytest.mark.parametrize('value', [None, '', ' \n\u200b', 3, [], {}])
def test_optional_artist_rejects_invalid_supplied_context(value):
    req = artist_request()
    req['interview_artist'] = value
    with pytest.raises(ValueError, match='interview_artist'):
        validate_request(req)


def test_context_participates_in_identity_only_when_present(tmp_path):
    req = artist_request()
    old = immutable_request(req)
    assert 'interview_artist' not in old
    req['interview_artist'] = 'River Vale'
    assert immutable_request(req)['interview_artist'] == 'River Vale'
    assert request_identity(req) != request_identity({k: v for k, v in req.items() if k != 'interview_artist'})
    journal(tmp_path, req)
    changed = copy.deepcopy(req)
    changed['interview_artist'] = 'Nova Reed'
    with pytest.raises(JournalRecoveryError):
        journal(tmp_path, changed)


def test_v4_discovery_prompt_is_byte_identical_to_v3():
    req = artist_request()
    args = (sentences_from_units(req['transcript_units']), {'intro': 'Useful commentary'}, 0, 9)
    assert _prompt(*args, discovery_prompt_version='configured-v4') == _prompt(*args, discovery_prompt_version='configured-v3')


def test_fields_v2_adds_scoped_user_context_but_v1_is_unchanged(tmp_path):
    req = artist_request(2, spotlight=False)
    req['interview_artist'] = 'River Vale'
    provider = ArtistProvider(intros=[(0, 1)], values={'artist-name': 'River Vale'})
    run(req, provider, tmp_path / 'new')
    prompt = next(p for s, p in provider.calls if s.startswith('extract:'))
    assert 'User-provided interview artist: "River Vale"' in prompt
    assert "subject's own music" in prompt
    assert 'other performers' in prompt and 'SELF' in prompt
    assert req['configuration']['fields'][0]['instructions'] in prompt
    req['options']['extraction_prompt_version'] = 'fields-v1'
    provider = ArtistProvider(intros=[(0, 1)], values={'artist-name': 'River Vale'})
    run(req, provider, tmp_path / 'old')
    old_prompt = next(p for s, p in provider.calls if s.startswith('extract:'))
    assert 'User-provided interview artist' not in old_prompt
    req.pop('interview_artist')
    provider2 = ArtistProvider(intros=[(0, 1)], values={'artist-name': 'River Vale'})
    run(req, provider2, tmp_path / 'old-absent')
    assert old_prompt == next(p for s, p in provider2.calls if s.startswith('extract:'))


@pytest.mark.parametrize('values,expected', [({}, 'spotlight'), ({'song-title': 'Paper Lanterns'}, 'intro'), ({'artist-name': 'River Vale'}, 'intro')])
def test_only_successful_double_null_reclassifies_intro(tmp_path, values, expected):
    req = artist_request()
    result = run(req, ArtistProvider(values=values), tmp_path)
    assert result['status'] == 'ready'
    assert [c['product_type'] for c in result['suggestions']] == [expected]
    item = result['suggestions'][0]
    assert item['candidate_id'] == _candidate_id(uuid.UUID(req['run_id']), item)
    if expected == 'spotlight':
        assert item['fields'] == {}


@pytest.mark.parametrize('duration,spotlight,expected', [(14, True, []), (15, True, ['spotlight']), (240, True, ['spotlight']), (20, False, [])])
def test_fallback_respects_spotlight_presence_and_duration(tmp_path, duration, spotlight, expected):
    req = artist_request(1, spotlight=spotlight)
    req['transcript_units'][0].update(end_sec=duration, end_sample=duration * 44100)
    result = run(req, ArtistProvider(intros=[(0, 0)]), tmp_path)
    assert [c['product_type'] for c in result['suggestions']] == expected


def test_qualification_fields_not_in_name_still_requested_and_never_leak(tmp_path):
    req = artist_request(naming=False)
    provider = ArtistProvider(values={'artist-name': 'River Vale'})
    result = run(req, provider, tmp_path)
    assert provider.extractions == 1
    assert result['suggestions'][0]['product_type'] == 'intro'
    assert result['suggestions'][0]['fields'] == {}
    prompt = next(p for s, p in provider.calls if s.startswith('extract:'))
    assert 'artist-name, song-title' in prompt


@pytest.mark.parametrize('removed', ['artist-name', 'song-title'])
def test_removed_qualification_definition_does_not_become_null_evidence(tmp_path, removed):
    req = artist_request(naming=False)
    req['configuration']['fields'] = [f for f in req['configuration']['fields'] if f['id'] != removed]
    provider = ArtistProvider()
    result = run(req, provider, tmp_path)
    assert [c['product_type'] for c in result['suggestions']] == ['intro']
    assert provider.extractions == 1
    assert result['suggestions'][0]['fields'] == {}


def spotlight_title(req):
    spotlight = next(t for t in req['configuration']['types'] if t['id'] == 'spotlight')
    spotlight.update(template=[dict(kind='field', value='descriptive-title')], sequenceFieldIDs=[])


def test_conversion_uses_spotlight_fields_new_id_and_replays_both_stages(tmp_path):
    req = artist_request()
    spotlight_title(req)
    provider = ArtistProvider(values={'descriptive-title': 'Space in the melody'})
    result = run(req, provider, tmp_path)
    assert provider.extractions == 2
    candidate = result['suggestions'][0]
    assert candidate['product_type'] == 'spotlight'
    assert candidate['fields'] == {'descriptive-title': 'Space in the melody'}
    assert candidate['candidate_id'] == _candidate_id(uuid.UUID(req['run_id']), candidate)
    retry = ArtistProvider()
    req['mode'] = 'resume'
    assert run(req, retry, tmp_path)['suggestions'] == result['suggestions']
    assert retry.calls == []


def test_prefers_overlapping_tuned_spotlight_and_deduplicates_conversion(tmp_path):
    req = artist_request(20)
    result = run(req, ArtistProvider(intros=[(0, 7), (8, 15)], spotlights=[(0, 19)]), tmp_path)
    assert [(c['product_type'], c['start_index'], c['end_index']) for c in result['suggestions']] == [('spotlight', 0, 19)]
    assert result['suggestions'][0]['label'] == 'Complete spotlight thought'


def test_failed_intro_remains_and_hides_spotlight_until_successful_retry(tmp_path):
    req = artist_request()
    provider = ArtistProvider(spotlights=[(0, 9)], fail=[1])
    first = run(req, provider, tmp_path)
    assert first['status'] == 'needs_retry'
    assert [c['product_type'] for c in first['suggestions']] == ['intro']
    assert first['suggestions'][0]['fields'] == {}
    retry = ArtistProvider()
    result = run(req, retry, tmp_path)
    assert result['status'] == 'ready'
    assert [c['product_type'] for c in result['suggestions']] == ['spotlight']
    assert len(retry.calls) == 1


def test_failed_fallback_retries_only_spotlight_naming(tmp_path):
    req = artist_request()
    spotlight_title(req)
    first = run(req, ArtistProvider(fail=[2]), tmp_path)
    assert first['status'] == 'needs_retry'
    assert [c['product_type'] for c in first['suggestions']] == ['spotlight']
    retry = ArtistProvider(values={'descriptive-title': 'Recovered title'})
    result = run(req, retry, tmp_path)
    assert len(retry.calls) == 1
    assert result['suggestions'][0]['fields'] == {'descriptive-title': 'Recovered title'}


@pytest.mark.parametrize('stage', [1, 2])
def test_successful_extraction_survives_checkpoint_failure_at_either_stage(tmp_path, monkeypatch, stage):
    req = artist_request()
    spotlight_title(req)
    provider = ArtistProvider(values={'descriptive-title': 'Saved title'})
    j = journal(tmp_path, req)
    original = j.write_checkpoint
    def write(**kwargs):
        if provider.extractions == stage:
            raise JournalStorageError('interrupted checkpoint')
        return original(**kwargs)
    monkeypatch.setattr(j, 'write_checkpoint', write)
    with pytest.raises(JournalStorageError):
        run_configured_suggest(req, provider, j, lambda e: None)
    retry = ArtistProvider(values={'descriptive-title': 'Saved title'})
    result = run(req, retry, tmp_path)
    assert result['status'] == 'ready'
    assert retry.extractions == 2 - stage
    assert result['suggestions'][0]['fields'] == {'descriptive-title': 'Saved title'}


def test_oversized_intro_evidence_is_diagnosed_without_disqualification(tmp_path):
    req = artist_request()
    req['transcript_units'][0]['text'] = 'Long evidence ' * 3000
    result = run(req, ArtistProvider(spotlights=[(0, 9)]), tmp_path)
    assert result['status'] == 'needs_retry'
    assert [c['product_type'] for c in result['suggestions']] == ['intro']
    assert result['failed_batches'][0]['kind'] == 'input_size'


def test_qualified_intro_still_hides_restored_spotlight(tmp_path):
    req = artist_request(30)
    qualified_id = _candidate_id(uuid.UUID(req['run_id']), dict(product_type='intro', start_index=0, end_index=7))
    provider = ArtistProvider(intros=[(0, 7), (20, 29)], spotlights=[(0, 9), (20, 29)],
                              values={qualified_id: {'artist-name': 'River Vale'}})
    result = run(req, provider, tmp_path)
    assert [(c['product_type'], c['start_index'], c['end_index']) for c in result['suggestions']] == [
        ('intro', 0, 7), ('spotlight', 20, 29)]


def test_custom_type_with_null_fields_is_not_qualified(tmp_path):
    req = artist_request(10, spotlight=False)
    intro = req['configuration']['types'][0]
    intro['id'] = 'custom-commentary'
    class CustomProvider(ArtistProvider):
        def complete(self, prompt, *, purpose=''):
            if purpose == 'configured-discovery':
                self.calls.append((purpose, prompt))
                return LLMResponse(json.dumps({'clips': [dict(type='custom-commentary', start=0, end=9,
                                                               label='Complete commentary')]}))
            return super().complete(prompt, purpose=purpose)
    result = run(req, CustomProvider(), tmp_path)
    assert [c['product_type'] for c in result['suggestions']] == ['custom-commentary']
    assert result['suggestions'][0]['fields'] == {'artist-name': None, 'song-title': None}


def test_resume_checkpoint_interruption_preserves_recovered_converted_fields(tmp_path, monkeypatch):
    req = artist_request()
    spotlight_title(req)
    first = run(req, ArtistProvider(values={'descriptive-title': 'Already saved'}), tmp_path)
    j = journal(tmp_path, req)
    original = j.write_checkpoint
    def write(**kwargs):
        result = original(**kwargs)
        if kwargs['phase'] == 'extracting':
            raise JournalStorageError('interrupted replay checkpoint')
        return result
    monkeypatch.setattr(j, 'write_checkpoint', write)
    with pytest.raises(JournalStorageError):
        run_configured_suggest(req, ArtistProvider(), j, lambda e: None)
    assert json.loads((tmp_path / 'checkpoint.json').read_text())['suggestions'] == first['suggestions']


def test_v2_large_subject_context_is_part_of_mandatory_budget(tmp_path):
    req = artist_request(1, spotlight=False)
    req['interview_artist'] = 'A' * 24000
    result = run(req, ArtistProvider(intros=[(0, 0)]), tmp_path)
    assert result['status'] == 'needs_retry'
    assert result['failed_batches'][0]['kind'] == 'input_size'
    assert [c['product_type'] for c in result['suggestions']] == ['intro']


def test_qualification_preserves_existing_tuned_selections_without_conversion():
    from cut_suggester.intro_qualification import qualify_intros
    req = artist_request(30)
    spotlights = [dict(candidate_id=str(i), product_type='spotlight', start_index=a, end_index=b)
                  for i, (a, b) in enumerate([(0, 19), (10, 29)])]
    assert qualify_intros(spotlights, {}, req['configuration'], req['run_id']) == spotlights


def test_small_nested_spotlight_does_not_replace_broader_complete_intro(tmp_path):
    req = artist_request(40)
    result = run(req, ArtistProvider(intros=[(0, 39)], spotlights=[(0, 9)]), tmp_path)
    assert [(c['product_type'], c['start_index'], c['end_index']) for c in result['suggestions']] == [
        ('spotlight', 0, 39)]


def test_retry_new_fallback_never_repeats_paid_unrelated_spotlight_naming(tmp_path):
    req = artist_request(30)
    spotlight_title(req)
    first = run(req, ArtistProvider(spotlights=[(20, 29)], fail=[1],
                                    values={'descriptive-title': 'Saved other story'}), tmp_path)
    saved = next(c for c in first['suggestions'] if c['product_type'] == 'spotlight')
    retry = ArtistProvider(values={'descriptive-title': 'New fallback story'})
    result = run(req, retry, tmp_path)
    assert result['status'] == 'ready'
    recovered = next(c for c in result['suggestions'] if c['candidate_id'] == saved['candidate_id'])
    assert recovered['fields'] == saved['fields']
    assert all(f"For candidate {saved['candidate_id']}" not in prompt for _, prompt in retry.calls)


def test_many_custom_named_spotlights_keep_twenty_candidate_batches(tmp_path):
    req = artist_request(820)
    req['options'].update(stage1_window=1000, stage1_step=900)
    spotlight_title(req)
    spans = [(i * 20, i * 20 + 9) for i in range(41)]
    provider = ArtistProvider(intros=[], spotlights=spans, values={'descriptive-title': 'A complete story'})
    result = run(req, provider, tmp_path)
    assert result['status'] == 'ready'
    assert len(result['suggestions']) == 41
    assert provider.extractions == 3


def test_changed_spotlight_set_reuses_success_ahead_of_checkpoint(tmp_path, monkeypatch):
    req = artist_request(30)
    spotlight_title(req)
    provider = ArtistProvider(spotlights=[(20, 29)], fail=[1],
                              values={'descriptive-title': 'Already paid story'})
    j = journal(tmp_path, req)
    original = j.write_checkpoint
    def write(**kwargs):
        if provider.extractions == 2:
            raise JournalStorageError('saved provider response ahead of checkpoint')
        return original(**kwargs)
    monkeypatch.setattr(j, 'write_checkpoint', write)
    with pytest.raises(JournalStorageError):
        run_configured_suggest(req, provider, j, lambda e: None)
    retry = ArtistProvider(values={'descriptive-title': 'New fallback story'})
    result = run(req, retry, tmp_path)
    saved_id = _candidate_id(uuid.UUID(req['run_id']), dict(product_type='spotlight', start_index=20, end_index=29))
    saved = next(c for c in result['suggestions'] if c['candidate_id'] == saved_id)
    assert saved['fields'] == {'descriptive-title': 'Already paid story'}
    assert all(f'For candidate {saved_id}' not in prompt for _, prompt in retry.calls)


def test_completed_extraction_cache_requires_exact_current_candidate_and_fields():
    from cut_suggester.extraction import completed_extraction_values
    def response(cid, fields):
        return json.dumps({'results': [dict(candidate_id=cid, fields=[
            dict(field_id=f, value=value) for f, value in fields.items()])]})
    records = [
        response('current', {'artist-name': 'Wrong field'}),
        response('foreign', {'descriptive-title': 'Wrong candidate'}),
        response('current', {'descriptive-title': 'Extra field response', 'artist-name': None}),
        '{"clips":[]}', '{"results":[{"candidate_id":"current","fields":false}]}',
    ]
    expected = {'current': frozenset({'descriptive-title'})}
    assert completed_extraction_values(records, expected) == {}
    records.append(response('current', {'descriptive-title': 'Saved title'}))
    assert completed_extraction_values(records, expected) == {'current': {'descriptive-title': 'Saved title'}}
