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
