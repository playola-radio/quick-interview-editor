import json

import pytest

from cut_suggester.run_journal import RunJournal, JournalRecoveryError, JournalStorageError


def test_completed_response_survives_independently_reopened_journal(tmp_path):
    calls = []
    def produce():
        calls.append(True)
        return '{"clips":[]}'
    j = RunJournal(tmp_path, request_identity='same-input')
    assert j.request('classify-key', produce, json.loads) == {'clips': []}
    reopened = RunJournal(tmp_path, request_identity='same-input')
    assert reopened.request('classify-key', produce, json.loads) == {'clips': []}
    assert len(calls) == 1


def test_failed_parser_is_recorded_and_retried(tmp_path):
    j = RunJournal(tmp_path, request_identity='input')
    with pytest.raises(ValueError):
        j.request('key', lambda: 'invalid', json.loads)
    assert j.failed_request_keys == ['key']
    reopened = RunJournal(tmp_path, request_identity='input')
    assert reopened.request('key', lambda: '{}', json.loads) == {}
    assert reopened.failed_request_keys == []


def test_corruption_never_calls_provider(tmp_path):
    j = RunJournal(tmp_path, request_identity='input')
    j.request('key', lambda: '{}', json.loads)
    record = next((tmp_path / 'requests').glob('*.json'))
    record.write_text('{')
    with pytest.raises(JournalRecoveryError):
        RunJournal(tmp_path, request_identity='input')


def test_identity_mismatch_rejected(tmp_path):
    RunJournal(tmp_path, request_identity='input')
    with pytest.raises(JournalRecoveryError, match='identity'):
        RunJournal(tmp_path, request_identity='other')


def test_interrupted_replace_preserves_completed_record_and_poison_stops_work(tmp_path, monkeypatch):
    import cut_suggester.run_journal as module
    j = RunJournal(tmp_path, request_identity='input')
    j.request('good', lambda: '{}', json.loads)
    def fail(*args):
        raise OSError('disk unavailable')
    monkeypatch.setattr(module.os, 'replace', fail)
    with pytest.raises(JournalStorageError):
        j.request('new', lambda: '{}', json.loads)
    with pytest.raises(JournalStorageError):
        j.request('another', lambda: pytest.fail('provider after disk error'), json.loads)
    reopened = RunJournal(tmp_path, request_identity='input')
    assert reopened.request('good', lambda: pytest.fail('paid rerun'), json.loads) == {}


def test_cancelled_provider_is_not_completed(tmp_path):
    j = RunJournal(tmp_path, request_identity='input')
    def cancel():
        raise KeyboardInterrupt()
    with pytest.raises(KeyboardInterrupt):
        j.request('key', cancel, json.loads)
    assert j.completed_request_keys == []
    assert not (tmp_path / 'checkpoint.json').exists()


def test_duplicate_identity_keys_are_visible_corruption(tmp_path):
    (tmp_path/'identity.json').write_text('{"schema_version":1,"request_identity":"wrong","request_identity":"input","immutable_request":null}')
    with pytest.raises(JournalRecoveryError):
        RunJournal(tmp_path,request_identity='input')


@pytest.mark.parametrize('mutation',[
    {'schema_version': True}, {'response': None}, {'response_sha256':'wrong'},
])
def test_malformed_completed_record_is_rejected_on_open(tmp_path,mutation):
    from cut_suggester.run_journal import digest
    j=RunJournal(tmp_path,request_identity='input')
    j.request('key',lambda:'{}',json.loads)
    path=next((tmp_path/'requests').glob('*.json'))
    record=json.loads(path.read_text())
    record.update(mutation)
    record.pop('integrity')
    record['integrity']=digest(record)
    path.write_text(json.dumps(record))
    with pytest.raises(JournalRecoveryError): RunJournal(tmp_path,request_identity='input')


def test_checkpoint_revision_overflow_stops_before_write(tmp_path):
    j=RunJournal(tmp_path,request_identity='input')
    j.checkpoint={'revision':2**63-1}
    with pytest.raises(JournalRecoveryError,match='revision'):
        j.write_checkpoint(run_id='id',phase='ready',suggestions=[],failed_batches=[])
    assert not (tmp_path/'checkpoint.json').exists()


def test_failed_attempt_storage_error_prevents_second_provider(tmp_path,monkeypatch):
    import cut_suggester.run_journal as module
    j=RunJournal(tmp_path,request_identity='input')
    monkeypatch.setattr(module.os,'replace',lambda *args: (_ for _ in ()).throw(OSError('disk failure')))
    with pytest.raises(JournalStorageError): j.request('key',lambda:'invalid',json.loads)
    with pytest.raises(JournalStorageError): j.request('key2',lambda:pytest.fail('second paid call'),json.loads)


def test_interrupted_checkpoint_keeps_old_revision_and_new_completed_request(tmp_path,monkeypatch):
    import cut_suggester.run_journal as module
    j=RunJournal(tmp_path,request_identity='input')
    j.write_checkpoint(run_id='id',phase='discovering',suggestions=[],failed_batches=[])
    j.request('new',lambda:'{}',json.loads)
    replace=module.os.replace
    def fail_checkpoint(source,target):
        if target.name=='checkpoint.json': raise OSError('interrupted checkpoint')
        replace(source,target)
    monkeypatch.setattr(module.os,'replace',fail_checkpoint)
    with pytest.raises(JournalStorageError): j.write_checkpoint(run_id='id',phase='ready',suggestions=[],failed_batches=[])
    reopened=RunJournal(tmp_path,request_identity='input')
    assert reopened.checkpoint['revision']==1
    assert reopened.request('new',lambda:pytest.fail('paid rerun'),json.loads)=={}


def test_checkpoint_missing_completed_record_is_recovery_error(tmp_path):
    j=RunJournal(tmp_path,request_identity='input')
    j.request('paid',lambda:'{}',json.loads)
    j.write_checkpoint(run_id='id',phase='ready',suggestions=[],failed_batches=[])
    next((tmp_path/'requests').glob('*.json')).unlink()
    with pytest.raises(JournalRecoveryError): RunJournal(tmp_path,request_identity='input')


def test_saved_response_is_revalidated_before_reuse(tmp_path):
    j=RunJournal(tmp_path,request_identity='input')
    j.request('key',lambda:'{}',json.loads)
    def reject(text): raise ValueError('no longer valid')
    with pytest.raises(JournalRecoveryError):
        RunJournal(tmp_path,request_identity='input').request('key',lambda:pytest.fail('paid rerun'),reject)
