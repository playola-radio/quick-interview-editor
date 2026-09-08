import copy
import json
from pathlib import Path
import re
import uuid

import pytest

from cut_suggester.configured_run import run_configured_suggest, request_identity, immutable_request, validate_request
from cut_suggester.run_journal import RunJournal, JournalRecoveryError, JournalStorageError
from cut_suggester.llm import LLMResponse


def request(n=1, fields=True, tuned=False):
    value = json.loads(Path('tests/fixtures/suggestion-contract-v2.json').read_text())
    chosen = 'intro' if tuned else 'image-id'
    value['configuration']['types'] = [t for t in value['configuration']['types'] if t['id'] == chosen]
    if fields:
        value['configuration']['types'][0]['template'] = [{'kind':'field','value':'descriptive-title'}]
        value['configuration']['types'][0]['sequenceFieldIDs'] = []
    elif tuned:
        value['configuration']['types'][0]['template'] = [{'kind':'sequence'}]
        value['configuration']['types'][0]['sequenceFieldIDs'] = []
    value['transcript_units'] = [dict(value['transcript_units'][0],id=i,word_ids=[i],start_sample=i*88200,end_sample=(i+1)*88200,start_sec=i*2,end_sec=(i+1)*2) for i in range(n)]
    return value


def journal(path, req):
    return RunJournal(path,request_identity=request_identity(req),immutable_request=immutable_request(req))


class Provider:
    def __init__(self, n=1, fail_batch=None, classify_failure=False, empty=False):
        self.n, self.fail_batch, self.classify_failure, self.empty = n, fail_batch, classify_failure, empty
        self.calls = []
        self.extractions = 0
    def complete(self,prompt,*,purpose=''):
        self.calls.append((purpose,prompt))
        if purpose.startswith('partition'):
            return LLMResponse(text='{"paragraphs":[{"start":0,"end":0,"label":"ID"}]}')
        if purpose.startswith('extract'):
            self.extractions += 1
            if self.extractions == self.fail_batch:
                raise RuntimeError('temporary provider failure')
            expected = re.findall(r'For candidate (.*?), return exactly these field IDs: (.*?)\.',prompt)
            return LLMResponse(text=json.dumps({'results':[{'candidate_id':cid,'fields':[{'field_id':field,'value':None} for field in fields.split(', ')]} for cid,fields in expected]}))
        if self.classify_failure:
            return LLMResponse(text='{"clips":[false]}')
        kind = 'intro' if purpose == 'classify' else 'image-id'
        return LLMResponse(text=json.dumps({'clips':[] if self.empty else [{'type':kind,'start':i,'end':i,'label':'ID','song':None} for i in range(self.n)]}))


def test_five_batches_keep_four_successes_after_reopen_and_retry_only_failure(tmp_path):
    req = request(81)
    provider = Provider(81, fail_batch=3)
    events=[]
    result = run_configured_suggest(req,provider,journal(tmp_path,req),events.append)
    assert provider.extractions == 5
    assert result['status'] == 'needs_retry'
    assert len([c for c in result['suggestions'] if c['fields']]) == 61
    assert len(result['failed_batches']) == 1
    checkpoint=json.loads((tmp_path/'checkpoint.json').read_text())
    assert checkpoint['phase'] == 'needs_retry'
    assert events[-1]['revision'] == checkpoint['revision']
    req['mode']='resume'
    retry=Provider(81)
    result=run_configured_suggest(req,retry,journal(tmp_path,req),lambda e:None)
    assert result['status'] == 'ready'
    assert len(retry.calls) == 1
    assert retry.extractions == 1
    assert all(c['fields'] == {'descriptive-title':None} for c in result['suggestions'])


def test_partition_success_survives_classification_failure(tmp_path):
    req=request(fields=False,tuned=True)
    provider=Provider(classify_failure=True)
    with pytest.raises(ValueError,match='no valid requested'):
        run_configured_suggest(req,provider,journal(tmp_path,req),lambda e:None)
    req['mode']='resume'
    retry=Provider()
    result=run_configured_suggest(req,retry,journal(tmp_path,req),lambda e:None)
    assert [purpose for purpose,_ in retry.calls] == ['classify']
    assert result['status']=='ready'


@pytest.mark.parametrize('empty',[False,True])
def test_numbered_types_and_valid_empty_skip_extraction(tmp_path,empty):
    req=request(fields=False)
    provider=Provider(empty=empty)
    result=run_configured_suggest(req,provider,journal(tmp_path,req),lambda e:None)
    assert result['status']=='ready'
    assert provider.extractions==0
    assert len(result['suggestions'])==(0 if empty else 1)


def test_changed_field_instructions_and_source_reject_same_run(tmp_path):
    req=request()
    original=journal(tmp_path,req)
    changed=copy.deepcopy(req)
    changed['configuration']['fields'][0]['instructions']+=' Updated unused field.'
    assert request_identity(changed)!=request_identity(req)
    with pytest.raises(JournalRecoveryError): journal(tmp_path,changed)
    changed=copy.deepcopy(req)
    changed['source_fingerprint']='other'
    with pytest.raises(JournalRecoveryError): journal(tmp_path,changed)
    assert original.completed_request_keys==[]


def test_fresh_run_different_uuid_bypasses_cache_and_resume_reuses(tmp_path):
    req=request(fields=False)
    provider=Provider()
    run_configured_suggest(req,provider,journal(tmp_path/'one',req),lambda e:None)
    req['mode']='resume'
    run_configured_suggest(req,provider,journal(tmp_path/'one',req),lambda e:None)
    assert len(provider.calls)==1
    req['mode']='fresh';req['run_id']=str(uuid.uuid4())
    run_configured_suggest(req,provider,journal(tmp_path/'two',req),lambda e:None)
    assert len(provider.calls)==2


@pytest.mark.parametrize('bad',[None,[],{}, {'schema_version':True},{'schema_version':3}])
def test_malformed_top_level_and_unsupported_version(bad):
    with pytest.raises(ValueError): validate_request(bad)


def test_checkpoint_write_failure_emits_no_checkpoint_and_stops_provider(tmp_path,monkeypatch):
    req=request(81)
    j=journal(tmp_path,req)
    def fail(**kwargs): raise JournalStorageError('disk full')
    monkeypatch.setattr(j,'write_checkpoint',fail)
    provider=Provider(81)
    events=[]
    with pytest.raises(JournalStorageError): run_configured_suggest(req,provider,j,events.append)
    assert provider.extractions==0
    assert not any(e['type']=='checkpoint' for e in events)


def test_cancellation_before_first_checkpoint_never_publishes(tmp_path):
    req=request(fields=False)
    class Cancelled:
        def complete(self,*args,**kwargs): raise KeyboardInterrupt()
    events=[]
    with pytest.raises(KeyboardInterrupt):
        run_configured_suggest(req,Cancelled(),journal(tmp_path,req),events.append)
    assert not (tmp_path/'checkpoint.json').exists()
    assert not any(e['type']=='checkpoint' for e in events)


def test_malformed_generic_response_is_not_replayed_as_empty(tmp_path):
    req=request(fields=False)
    with pytest.raises(ValueError):
        run_configured_suggest(req,Provider(classify_failure=True),journal(tmp_path,req),lambda e:None)
    provider=Provider(empty=True)
    result=run_configured_suggest(req,provider,journal(tmp_path,req),lambda e:None)
    assert len(provider.calls)==1
    assert result['status']=='ready'


def test_oversized_extraction_records_nonretryable_diagnostic(tmp_path):
    req=request()
    req['transcript_units'][0]['text']='Long evidence ' * 3000
    provider=Provider()
    result=run_configured_suggest(req,provider,journal(tmp_path,req),lambda e:None)
    assert result['status']=='needs_retry'
    assert result['failed_batches'][0]['kind']=='input_size'
    assert result['failed_batches'][0]['retryable'] is False
    assert provider.extractions==0
    retry=Provider()
    run_configured_suggest(req,retry,journal(tmp_path,req),lambda e:None)
    assert retry.calls==[]


def test_resume_cancellation_keeps_previously_checkpointed_fields(tmp_path):
    req=request(81)
    first=run_configured_suggest(req,Provider(81,fail_batch=1),journal(tmp_path,req),lambda e:None)
    completed={c['candidate_id']:c['fields'] for c in first['suggestions'] if c['fields']}
    class Cancelled:
        def complete(self,*args,**kwargs): raise KeyboardInterrupt()
    req['mode']='resume'
    with pytest.raises(KeyboardInterrupt):
        run_configured_suggest(req,Cancelled(),journal(tmp_path,req),lambda e:None)
    checkpoint=json.loads((tmp_path/'checkpoint.json').read_text())
    assert all(c['fields']==completed[c['candidate_id']] for c in checkpoint['suggestions'] if c['candidate_id'] in completed)


class RefiningProvider(Provider):
    def complete(self, prompt, *, purpose=''):
        if purpose == 'classify':
            self.calls.append((purpose, prompt))
            return LLMResponse(json.dumps({'clips': [dict(type='intro', start=0, end=3,
                                                          label='Coarse handoffs', song=None)]}))
        if purpose.startswith('refine-intros:'):
            self.calls.append((purpose, prompt))
            return LLMResponse(json.dumps({'results': [{'proposal_id': 'p0', 'takes': [
                dict(start=0, end=1, label='First handoff', song=None),
                dict(start=2, end=3, label='Second handoff', song=None),
            ]}]}))
        return super().complete(prompt, purpose=purpose)


@pytest.mark.parametrize('version,spans', [
    ('configured-v2', [(0, 1), (2, 3)]),
    ('v2', [(0, 3)]), ('configured-v1', [(0, 3)]), ('captured-old-version', [(0, 3)]),
])
def test_discovery_behavior_version_preserves_captured_path(tmp_path, version, spans):
    req = request(4, fields=False, tuned=True)
    req['options']['discovery_prompt_version'] = version
    provider = RefiningProvider()
    result = run_configured_suggest(req, provider, journal(tmp_path, req), lambda e: None)
    assert [(c['start_index'], c['end_index']) for c in result['suggestions']] == spans
    assert sum(stage.startswith('refine-intros:') for stage, _ in provider.calls) == (version == 'configured-v2')


def test_saved_refinement_replays_after_checkpoint_interruption(tmp_path, monkeypatch):
    req = request(4, fields=True, tuned=True)
    req['options']['discovery_prompt_version'] = 'configured-v2'
    j = journal(tmp_path, req)
    original = j.write_checkpoint
    def interrupted(**kwargs):
        if len(j.completed_request_keys) == 3:
            raise JournalStorageError('interrupted after saved refinement')
        return original(**kwargs)
    monkeypatch.setattr(j, 'write_checkpoint', interrupted)
    provider = RefiningProvider()
    with pytest.raises(JournalStorageError):
        run_configured_suggest(req, provider, j, lambda e: None)
    assert len(j.completed_request_keys) == 3
    req['mode'] = 'resume'
    retry = RefiningProvider()
    result = run_configured_suggest(req, retry, journal(tmp_path, req), lambda e: None)
    assert result['status'] == 'ready'
    assert len(retry.calls) == 1 and retry.calls[0][0].startswith('extract:')
    assert [(c['start_index'], c['end_index']) for c in result['suggestions']] == [(0, 1), (2, 3)]
    from cut_suggester.configured_discovery import _candidate_id
    old_id = _candidate_id(uuid.UUID(req['run_id']), dict(product_type='intro', start_index=0, end_index=3))
    assert old_id not in retry.calls[0][1]
    assert all(c['candidate_id'] in retry.calls[0][1] for c in result['suggestions'])


def test_new_version_without_intro_skips_refinement(tmp_path):
    req = request(fields=False)
    req['options']['discovery_prompt_version'] = 'configured-v2'
    provider = Provider()
    run_configured_suggest(req, provider, journal(tmp_path, req), lambda e: None)
    assert [stage for stage, _ in provider.calls] == ['configured-discovery']
    assert 'Each independently complete performance' in provider.calls[0][1]


def test_changed_final_bounds_do_not_inherit_recovered_fields(tmp_path):
    from cut_suggester.configured_discovery import _candidate_id
    req = request(4, fields=True, tuned=True)
    req['options']['discovery_prompt_version'] = 'configured-v2'
    old_id = _candidate_id(uuid.UUID(req['run_id']), dict(product_type='intro', start_index=0, end_index=3))
    j = journal(tmp_path, req)
    j.write_checkpoint(run_id=req['run_id'], phase='needs_retry', failed_batches=[],
                       suggestions=[dict(candidate_id=old_id, fields={'descriptive-title': 'Old bounds title'})])
    provider = RefiningProvider(fail_batch=1)
    result = run_configured_suggest(req, provider, j, lambda e: None)
    assert result['status'] == 'needs_retry'
    assert all(c['candidate_id'] != old_id and c['fields'] == {} for c in result['suggestions'])


def test_malformed_refinement_never_becomes_completed_paid_record(tmp_path):
    req = request(4, fields=False, tuned=True)
    req['options']['discovery_prompt_version'] = 'configured-v2'
    class Invalid(RefiningProvider):
        def complete(self, prompt, *, purpose=''):
            if purpose.startswith('refine-intros:'):
                self.calls.append((purpose, prompt))
                return LLMResponse('{"results":[]}')
            return super().complete(prompt, purpose=purpose)
    with pytest.raises(ValueError, match='missing an expected proposal'):
        run_configured_suggest(req, Invalid(), journal(tmp_path, req), lambda e: None)
    recovered = journal(tmp_path, req)
    assert len(recovered.completed_request_keys) == 2
    assert len(recovered.failed_request_keys) == 1
    assert recovered.checkpoint['suggestions'] == []


def integration_request():
    from evals.cut_suggestions.editorial_runner import build_request
    from cut_suggester.run_journal import digest
    req = build_request(model='fixture-model')
    req['configuration']['types'].append(dict(
        id='custom-story', name='Community Story', group='spotlights',
        guidelines='A complete story about a shared neighborhood project.',
        template=[dict(kind='field', value='descriptive-title')], sequenceFieldIDs=[]))
    seed = {key: req[key] for key in ('transcript_units', 'configuration', 'options')}
    req['run_id'] = str(uuid.uuid5(uuid.NAMESPACE_URL, 'playola-editorial:' + digest(seed)))
    return req


class AllTypesProvider:
    """Explicit transport fixture. These scripted decisions are not model evidence."""
    def __init__(self, req, fail_extraction=None):
        from cut_suggester.configured_discovery import _candidate_id
        self.calls = []
        self.extractions = 0
        self.fail_extraction = fail_extraction
        self.values = {}
        for kind, start, end, fields in [
            ('intro', 0, 3, {'artist-name': 'River Vale', 'song-title': 'Paper Lanterns'}),
            ('intro', 24, 25, {'artist-name': 'Nova Reed', 'song-title': 'Harbor Lights'}),
            ('custom-story', 29, 36, {'descriptive-title': 'Neighbors build a shared studio'}),
        ]:
            cid = _candidate_id(uuid.UUID(req['run_id']), dict(product_type=kind, start_index=start, end_index=end))
            self.values[cid] = fields

    def complete(self, prompt, *, purpose=''):
        self.calls.append((purpose, prompt))
        if purpose.startswith('partition:'):
            data = {'paragraphs': [dict(start=a, end=b, label=label) for a, b, label in [
                (0, 3, 'River recording'), (4, 7, 'Station takes'), (8, 22, 'Membership'),
                (23, 28, 'Nova transition'), (29, 36, 'Shared studio'), (37, 38, 'False start')]]}
        elif purpose == 'classify':
            data = {'clips': [dict(type=kind, start=a, end=b, label=label, song=song)
                              for kind, a, b, label, song in [
                                  ('intro', 0, 3, 'River recording introduction', 'Paper Lanterns'),
                                  ('intro', 23, 28, 'Nova recording introduction', 'Harbor Lights'),
                                  ('spotlight', 29, 36, 'Mara neighborhood studio', None)]]}
        elif purpose.startswith('refine-intros:'):
            data = {'results': [dict(proposal_id=reference, takes=[dict(start=a, end=b, label=label, song=song)])
                                for reference, a, b, label, song in [
                                    ('p0', 0, 3, 'River recording introduction', 'Paper Lanterns'),
                                    ('p1', 24, 25, 'Nova recording introduction', 'Harbor Lights')]]}
        elif purpose == 'configured-discovery':
            labels = json.loads(Path('evals/cut_suggestions/datasets/suggestion_types/labels.json').read_text())
            clips = [dict(type=p['type'], start=p['start'], end=p['end'], label=p['note'])
                     for p in labels['positives'] if p['type'].startswith('image-')]
            clips.append(dict(type='custom-story', start=29, end=36, label='Shared studio story'))
            data = {'clips': clips}
        elif purpose.startswith('extract:'):
            self.extractions += 1
            if self.extractions == self.fail_extraction:
                raise RuntimeError('interrupted naming batch')
            expected = re.findall(r'For candidate (.*?), return exactly these field IDs: (.*?)\.', prompt)
            data = {'results': [dict(candidate_id=cid, fields=[dict(field_id=f, value=self.values[cid][f])
                                                            for f in field_ids.split(', ')])
                                for cid, field_ids in expected]}
        else:
            raise AssertionError(f'unexpected provider stage {purpose}')
        return LLMResponse(json.dumps(data))


def test_all_types_custom_fixture_failed_naming_reopen_and_final_transport(tmp_path, monkeypatch):
    import cut_suggester.configured_run as configured
    original = configured.plan_extraction_batches
    monkeypatch.setattr(configured, 'plan_extraction_batches',
                        lambda *args, **kwargs: original(*args, **kwargs, max_candidates=1))
    req = integration_request()
    provider = AllTypesProvider(req, fail_extraction=2)
    failed = run_configured_suggest(req, provider, journal(tmp_path, req), lambda e: None)
    assert failed['status'] == 'needs_retry'
    assert provider.extractions == 3
    assert len(failed['failed_batches']) == 1
    preserved = {c['candidate_id']: c['fields'] for c in failed['suggestions'] if c['fields']}
    assert len(preserved) == 2
    req['mode'] = 'resume'
    retry = AllTypesProvider(req)
    result = run_configured_suggest(req, retry, journal(tmp_path, req), lambda e: None)
    assert result['status'] == 'ready'
    assert len(retry.calls) == 1 and retry.calls[0][0].startswith('extract:')
    assert len(result['suggestions']) == 10
    assert {c['product_type'] for c in result['suggestions']} == {
        'intro', 'spotlight', 'image-id', 'image-promo', 'image-pre-commercial',
        'image-post-commercial', 'custom-story'}
    assert all(c['fields'] == preserved[c['candidate_id']] for c in result['suggestions'] if c['candidate_id'] in preserved)
    assert result == json.loads(Path('tests/fixtures/suggestion-integration-response-v2.json').read_text())
    assert integration_request() == json.loads(Path('tests/fixtures/suggestion-integration-request-v2.json').read_text())
