"""Per-run durable records for validated provider responses and checkpoints."""

from __future__ import annotations

import errno
import hashlib
import json
import os
from pathlib import Path
import tempfile
from typing import Callable, TypeVar

T = TypeVar('T')


class JournalRecoveryError(ValueError):
    """Existing recovery data is inconsistent; paid work must not be repeated."""


class JournalStorageError(OSError):
    """Persistence failed; this journal cannot authorize more provider work."""


def canonical_json(value: object) -> str:
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False, allow_nan=False)


def digest(value: object) -> str:
    return hashlib.sha256(canonical_json(value).encode('utf-8')).hexdigest()


def _unique_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f'duplicate JSON key {key!r}')
        result[key] = value
    return result


class RunJournal:
    """The directory is already per-run; no owner manifest is touched here."""

    def __init__(self, directory, *, request_identity: str, immutable_request: dict | None = None):
        if not isinstance(request_identity, str) or not request_identity:
            raise ValueError('request_identity must be a nonempty string')
        if immutable_request is not None and digest(immutable_request) != request_identity:
            raise JournalRecoveryError('immutable request does not match identity')
        self.directory = Path(directory)
        self.request_identity = request_identity
        self._storage_error = None
        self._records: dict[str, dict] = {}
        self.checkpoint = None
        try:
            self.directory.mkdir(parents=True, exist_ok=True)
            (self.directory / 'requests').mkdir(exist_ok=True)
        except OSError as exc:
            raise JournalStorageError(str(exc)) from exc
        identity_path = self.directory / 'identity.json'
        if identity_path.exists():
            identity = self._read(identity_path)
            if type(identity.get('schema_version')) is not int or identity['schema_version'] != 1 or identity.get('request_identity') != request_identity or 'immutable_request' not in identity:
                raise JournalRecoveryError('journal identity does not match request')
            stored = identity.get('immutable_request')
            if stored is not None and digest(stored) != request_identity:
                raise JournalRecoveryError('journal immutable request identity is corrupt')
            if immutable_request is not None and stored is not None and stored != immutable_request:
                raise JournalRecoveryError('journal immutable request does not match request')
        else:
            stored = immutable_request
            if any((self.directory / 'requests').glob('*.json')) or (self.directory / 'checkpoint.json').exists():
                raise JournalRecoveryError('journal identity is missing')
            self._write(identity_path, {
                'schema_version': 1, 'request_identity': request_identity,
                'immutable_request': immutable_request,
            })
        self.immutable_request = stored
        if immutable_request is not None:
            self.bind_request(immutable_request)
        for path in (self.directory / 'requests').glob('*.json'):
            record = self._read(path)
            key = record.get('key')
            if (type(record.get('schema_version')) is not int or record['schema_version'] != 1 or record.get('request_identity') != request_identity
                    or not isinstance(key, str) or path.name != digest(key) + '.json'
                    or record.get('status') not in ('completed', 'failed')
                    or record.get('integrity') != digest({k: v for k, v in record.items() if k != 'integrity'})):
                raise JournalRecoveryError(f'corrupt request record: {path.name}')
            if record['status'] == 'completed':
                response = record.get('response')
                if not isinstance(response, str) or record.get('response_sha256') != hashlib.sha256(response.encode('utf-8')).hexdigest():
                    raise JournalRecoveryError(f'corrupt completed response: {path.name}')
            elif not isinstance(record.get('error_type'), str):
                raise JournalRecoveryError(f'corrupt failure record: {path.name}')
            self._records[key] = record
        checkpoint_path = self.directory / 'checkpoint.json'
        if checkpoint_path.exists():
            checkpoint = self._read(checkpoint_path)
            if (type(checkpoint.get('schema_version')) is not int or checkpoint['schema_version'] != 1 or checkpoint.get('request_identity') != request_identity
                    or type(checkpoint.get('revision')) is not int or not 1 <= checkpoint['revision'] <= 2**63 - 1
                    or checkpoint.get('integrity') != digest({k: v for k, v in checkpoint.items() if k != 'integrity'})):
                raise JournalRecoveryError('corrupt checkpoint')
            for field in ('completed_request_keys', 'failed_request_keys'):
                if not isinstance(checkpoint.get(field), list) or any(not isinstance(key, str) for key in checkpoint[field]):
                    raise JournalRecoveryError(f'corrupt checkpoint {field}')
            if not set(checkpoint['completed_request_keys']).issubset(self.completed_request_keys):
                raise JournalRecoveryError('checkpoint has missing completed request records')
            if (checkpoint.get('phase') not in ('discovering', 'extracting', 'needs_retry', 'ready')
                    or not isinstance(checkpoint.get('suggestions'), list)
                    or not isinstance(checkpoint.get('failed_batches'), list)
                    or (self.immutable_request is not None and checkpoint.get('run_id') != self.immutable_request['run_id'])):
                raise JournalRecoveryError('corrupt checkpoint envelope')
            self.checkpoint = checkpoint

    def bind_request(self, immutable_request: dict):
        """Attach the semantic request snapshot before the first paid call."""
        if digest(immutable_request) != self.request_identity:
            raise JournalRecoveryError('immutable request does not match identity')
        if self.immutable_request is None:
            self._write(self.directory / 'identity.json', {
                'schema_version': 1, 'request_identity': self.request_identity,
                'immutable_request': immutable_request,
            })
            self.immutable_request = json.loads(canonical_json(immutable_request))
        elif digest(self.immutable_request) != digest(immutable_request):
            raise JournalRecoveryError('immutable request does not match journal')

    @staticmethod
    def _read(path: Path) -> dict:
        try:
            value = json.loads(path.read_text(encoding='utf-8'), object_pairs_hook=_unique_keys)
            if not isinstance(value, dict):
                raise ValueError('expected object')
            return value
        except (OSError, ValueError, UnicodeError) as exc:
            raise JournalRecoveryError(f'cannot recover {path.name}: {exc}') from exc

    def _check_storage(self):
        if self._storage_error is not None:
            raise JournalStorageError(str(self._storage_error)) from self._storage_error

    def _write(self, path: Path, value: dict):
        self._check_storage()
        temp_path = None
        try:
            with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=path.parent, prefix='.pending-', delete=False) as stream:
                temp_path = Path(stream.name)
                stream.write(canonical_json(value))
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temp_path, path)
            fd = os.open(path.parent, os.O_RDONLY)
            try:
                try:
                    os.fsync(fd)
                except OSError as exc:
                    if exc.errno not in (errno.EINVAL, errno.ENOTSUP):
                        raise
            finally:
                os.close(fd)
        except OSError as exc:
            self._storage_error = exc
            raise JournalStorageError(str(exc)) from exc
        finally:
            if temp_path is not None:
                try:
                    temp_path.unlink(missing_ok=True)
                except OSError:
                    # A leftover temporary file is ignored on recovery. Keep the
                    # original persistence error, which must stop paid work.
                    pass

    @property
    def completed_request_keys(self):
        return sorted(k for k, r in self._records.items() if r['status'] == 'completed')

    @property
    def failed_request_keys(self):
        return sorted(k for k, r in self._records.items() if r['status'] == 'failed')

    def request(self, key: str, invoke: Callable[[], str], validate: Callable[[str], T]) -> T:
        self._check_storage()
        record = self._records.get(key)
        if record is not None and record['status'] == 'completed':
            try:
                return validate(record['response'])
            except Exception as exc:
                raise JournalRecoveryError(f'completed request {key} no longer validates: {exc}') from exc
        record = {'schema_version': 1, 'request_identity': self.request_identity, 'key': key}
        try:
            response = invoke()
            result = validate(response)
        except Exception as exc:
            record.update(status='failed', error_type=type(exc).__name__)
            self._save_record(key, record)
            raise
        record.update(status='completed', response=response, response_sha256=hashlib.sha256(response.encode('utf-8')).hexdigest())
        self._save_record(key, record)
        return result

    def _save_record(self, key, record):
        record['integrity'] = digest(record)
        self._write(self.directory / 'requests' / (digest(key) + '.json'), record)
        self._records[key] = record

    def write_checkpoint(self, *, run_id: str, phase: str, suggestions: list, failed_batches: list) -> dict:
        revision = (self.checkpoint['revision'] if self.checkpoint else 0) + 1
        if revision > 2**63 - 1:
            raise JournalRecoveryError('checkpoint revision exhausted')
        checkpoint = {
            'schema_version': 1, 'run_id': run_id, 'request_identity': self.request_identity,
            'revision': revision,
            'phase': phase, 'suggestions': suggestions,
            'completed_request_keys': self.completed_request_keys,
            'failed_request_keys': self.failed_request_keys, 'failed_batches': failed_batches,
        }
        checkpoint['integrity'] = digest(checkpoint)
        self._write(self.directory / 'checkpoint.json', checkpoint)
        # Keep a detached snapshot, not the orchestrator's mutable candidate list.
        self.checkpoint = json.loads(canonical_json(checkpoint))
        return self.checkpoint
