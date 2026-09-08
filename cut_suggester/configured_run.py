"""Validated V2 suggestion runs with per-request durable recovery."""

from __future__ import annotations

from dataclasses import asdict
import math
import uuid

from .configured_discovery import _candidate_id, _overlap, _span_length, discover_configured
from .cutter import suggest_cuts
from .extraction import parse_extraction_response, plan_extraction_batches
from .run_journal import JournalRecoveryError, JournalStorageError, RunJournal, canonical_json, digest
from .suggestion_config import (
    BROAD_INTRO_DISCOVERY_VERSION, CONFIGURED_DISCOVERY_VERSION,
    split_discovery_types, validate_configuration,
)
from .transcript import sentences_from_units

_OPTION_KEYS = ('model', 'sample_rate', 'stage1_window', 'stage1_step',
                'discovery_prompt_version', 'extraction_prompt_version', 'product_spec_version')
_IMMUTABLE_KEYS = ('schema_version', 'run_id', 'transcript_hash', 'source_fingerprint',
                   'transcript_units', 'configuration')


def validate_request(request: object) -> None:
    if not isinstance(request, dict):
        raise ValueError('request must be an object')
    if type(request.get('schema_version')) is not int or request['schema_version'] != 2:
        raise ValueError('unsupported schema_version; expected 2')
    if request.get('mode') not in ('fresh', 'automatic', 'resume'):
        raise ValueError('mode must be fresh, automatic, or resume')
    try:
        uuid.UUID(request['run_id'])
    except (KeyError, ValueError, TypeError, AttributeError) as exc:
        raise ValueError('run_id must be a UUID') from exc
    for name in ('transcript_hash', 'source_fingerprint'):
        if not isinstance(request.get(name), str) or not request[name].strip():
            raise ValueError(f'{name} must be a nonblank string')
    options = request.get('options')
    if not isinstance(options, dict):
        raise ValueError('options must be an object')
    for name in _OPTION_KEYS:
        value = options.get(name)
        if name in ('sample_rate', 'stage1_window', 'stage1_step'):
            if type(value) is not int or value <= 0:
                raise ValueError(f'{name} must be a positive integer')
        elif not isinstance(value, str) or not value.strip():
            raise ValueError(f'{name} must be a nonblank string')
    if options['stage1_step'] > options['stage1_window']:
        raise ValueError('stage1_step must not exceed stage1_window')
    validate_configuration(request.get('configuration'))
    units = request.get('transcript_units')
    if not isinstance(units, list) or not units:
        raise ValueError('request has no transcript_units to analyze')
    seen = set()
    for unit in units:
        if not isinstance(unit, dict):
            raise ValueError('transcript unit must be an object')
        for name in ('id', 'start_sample', 'end_sample'):
            if type(unit.get(name)) is not int or unit[name] < 0:
                raise ValueError(f'transcript unit {name} must be a nonnegative integer')
        if unit['id'] in seen:
            raise ValueError('duplicate transcript unit id')
        seen.add(unit['id'])
        if not isinstance(unit.get('text'), str) or not unit['text'].strip():
            raise ValueError('transcript unit has empty text')
        if not isinstance(unit.get('word_ids'), list) or not unit['word_ids'] or any(type(w) is not int or w < 0 for w in unit['word_ids']):
            raise ValueError('transcript unit must have integer word_ids')
        for name in ('start_sec', 'end_sec'):
            value = unit.get(name)
            if type(value) not in (int, float) or not math.isfinite(value) or value < 0:
                raise ValueError(f'transcript unit {name} must be a finite nonnegative number')
        if unit['end_sample'] < unit['start_sample'] or unit['end_sec'] < unit['start_sec']:
            raise ValueError('transcript unit has reversed bounds')
        if unit.get('speaker_id') is not None and not isinstance(unit['speaker_id'], str):
            raise ValueError('speaker_id must be a string or null')
    canonical_json(immutable_request(request))


def immutable_request(request: dict) -> dict:
    """Only protocol input: exclude execution mode, credentials and path options."""
    return {**{name: request[name] for name in _IMMUTABLE_KEYS},
            'options': {name: request['options'][name] for name in _OPTION_KEYS}}


def request_identity(request: dict) -> str:
    validate_request(request)
    return digest(immutable_request(request))


def run_configured_suggest(request: dict, llm, journal: RunJournal, emit) -> dict:
    validate_request(request)
    if journal.request_identity != request_identity(request):
        raise JournalRecoveryError('journal identity does not match request')
    journal.bind_request(immutable_request(request))
    run_id = request['run_id']
    options, configuration = request['options'], request['configuration']
    sentences = sentences_from_units(request['transcript_units'])
    suggestions = []
    failed_batches = []
    recovered = journal.checkpoint['suggestions'] if journal.checkpoint else []
    recovered_fields = {c['candidate_id']: c.get('fields', {}) for c in recovered}
    discovery_complete = False

    def checkpoint(phase):
        saved = journal.write_checkpoint(run_id=run_id, phase=phase,
                                        suggestions=(recovered if recovered and not discovery_complete else suggestions),
                                        failed_batches=failed_batches)
        emit({'type': 'checkpoint', 'run_id': run_id, 'revision': saved['revision']})
        return saved

    def progress(**event):
        emit({'type': 'progress', **event})

    def validated_request(stage, prompt, validate):
        key = digest({'request_identity': journal.request_identity, 'stage': stage, 'prompt': prompt})
        result = journal.request(key, lambda: llm.complete(prompt, purpose=stage).text, validate)
        checkpoint('discovering')
        return result

    broad_intros = options['discovery_prompt_version'] == BROAD_INTRO_DISCOVERY_VERSION
    tuned, generic = split_discovery_types(configuration, discovery_prompt_version=options['discovery_prompt_version'])
    try:
        if tuned:
            # Keep captured requests immutable and the tuned Spotlight implementation unchanged.
            tuned_configuration = {**configuration, 'types': tuned} if broad_intros else configuration
            result = suggest_cuts(sentences, llm, configuration=tuned_configuration,
                                  refine_intros=options['discovery_prompt_version'] == CONFIGURED_DISCOVERY_VERSION,
                                  sample_rate=options['sample_rate'], window=options['stage1_window'],
                                  step=options['stage1_step'], progress=progress,
                                  validated_request=validated_request)
            for candidate in result.candidates:
                item = candidate.to_dict()
                item['candidate_id'] = _candidate_id(uuid.UUID(run_id), item)
                item['fields'] = recovered_fields.get(item['candidate_id'], {}).copy()
                suggestions.append(item)
            checkpoint('discovering')
        if generic:
            progress(phase='discovering', message='Finding configured clips')
            suggestions.extend(discover_configured(
                sentences, generic, llm, run_id=run_id, sample_rate=options['sample_rate'],
                window=options['stage1_window'], step=options['stage1_step'],
                discovery_prompt_version=options['discovery_prompt_version'],
                validated_request=validated_request))
    except (JournalStorageError, JournalRecoveryError):
        raise
    except Exception:
        checkpoint('needs_retry')
        raise
    discovery_complete = True
    if broad_intros:
        intros = [item for item in suggestions if item['product_type'] == 'intro']
        suggestions = [item for item in suggestions
                       if item['product_type'] != 'spotlight'
                       or not any(_overlap(item, intro) / _span_length(item) >= 0.8 for intro in intros)]
    suggestions.sort(key=lambda c: (c['start_index'], c['end_index'], c['product_type']))
    for candidate in suggestions:
        candidate['fields'] = recovered_fields.get(candidate['candidate_id'], {}).copy()
    plan = plan_extraction_batches(
        suggestions, configuration['types'], configuration['fields'], sentences,
        speaker_ids={u['id']: u.get('speaker_id') for u in request['transcript_units']})
    failed_batches.extend({'kind': 'input_size', 'retryable': False, **asdict(d)} for d in plan.input_size_diagnostics)
    checkpoint('extracting')
    by_id = {c['candidate_id']: c for c in suggestions}
    for index, batch in enumerate(plan.batches):
        stage = f'extract:{batch.stable_key}'
        key = digest({'request_identity': journal.request_identity, 'stage': stage, 'prompt': batch.prompt})
        progress(phase='extracting', message=f'Naming batch {index + 1} of {len(plan.batches)}', index=index + 1, total=len(plan.batches))
        try:
            values = journal.request(key, lambda: llm.complete(batch.prompt, purpose=stage).text,
                                     lambda text: parse_extraction_response(text, batch.expected))
        except (JournalStorageError, JournalRecoveryError):
            raise
        except Exception as exc:
            failed_batches.append({'kind': 'extraction', 'request_key': key,
                                   'candidate_ids': list(batch.candidate_ids), 'retryable': True,
                                   'error_type': type(exc).__name__})
        else:
            for candidate_id, fields in values.items():
                by_id[candidate_id]['fields'] = fields
        checkpoint('extracting')
    status = 'needs_retry' if failed_batches else 'ready'
    saved = checkpoint(status)
    return {'schema_version': 2, 'run_id': run_id, 'checkpoint_revision': saved['revision'],
            'status': status, 'suggestions': suggestions, 'failed_batches': failed_batches}
