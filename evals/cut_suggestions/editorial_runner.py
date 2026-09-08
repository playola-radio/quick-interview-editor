"""Configured synthetic editorial evaluation with actual-response offline replay.

Live mode uses the existing provider integration and saves raw responses. Cached
mode never constructs a live provider. Both execute the full configured pipeline.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import tempfile
import uuid

from cut_suggester.cache import CachingLLMClient
from cut_suggester.configured_discovery import same_take
from cut_suggester.configured_run import immutable_request, request_identity, run_configured_suggest
from cut_suggester.llm import live_client_for
from cut_suggester.run_journal import RunJournal, digest
from cut_suggester.suggestion_config import CONFIGURED_DISCOVERY_VERSION
from cut_suggester.transcript import load_transcript

_HERE = Path(__file__).resolve().parent
DEFAULT_DATASET = _HERE / 'datasets' / 'suggestion_types'
DEFAULT_CACHE = _HERE / 'editorial_cache'
CONTRACT = _HERE.parent.parent / 'tests' / 'fixtures' / 'suggestion-contract-v2.json'


def build_request(dataset_dir=DEFAULT_DATASET, *, model='gpt-4o',
                  discovery_version=CONFIGURED_DISCOVERY_VERSION) -> dict:
    dataset = Path(dataset_dir)
    labels = json.loads((dataset / 'labels.json').read_text())
    transcript = dataset / labels.get('transcript', 'transcript.json')
    configuration = json.loads(CONTRACT.read_text())['configuration']
    sentences = load_transcript(str(transcript), sample_rate=44100)
    units = [dict(id=s.segment_id, text=s.text, word_ids=list(s.word_ids),
                  start_sample=s.start_sample, end_sample=s.end_sample,
                  start_sec=s.start_sec, end_sec=s.end_sec) for s in sentences]
    options = dict(model=model, sample_rate=44100, stage1_window=130, stage1_step=110,
                   discovery_prompt_version=discovery_version,
                   extraction_prompt_version='fields-v1', product_spec_version='configured-v1')
    seed = dict(transcript_units=units, configuration=configuration, options=options)
    return dict(schema_version=2,
                run_id=str(uuid.uuid5(uuid.NAMESPACE_URL, 'playola-editorial:' + digest(seed))),
                mode='fresh', transcript_hash=digest(units),
                source_fingerprint=hashlib.sha256(transcript.read_bytes()).hexdigest(), **seed)


def _span(label):
    return dict(start_index=label['start'], end_index=label['end'])


def editorial_metrics(predictions: list[dict], labels: dict) -> dict:
    positives = labels['positives']
    edges = [[i for i, candidate in enumerate(predictions)
              if candidate['product_type'] == label['type'] and same_take(candidate, _span(label))]
             for label in positives]
    # Deterministic augmenting paths give a maximum one-to-one matching, unlike
    # counting every label touched by a single overbroad prediction.
    owners = {}
    def match(label_index, visited):
        for candidate_index in edges[label_index]:
            if candidate_index in visited:
                continue
            visited.add(candidate_index)
            if candidate_index not in owners or match(owners[candidate_index], visited):
                owners[candidate_index] = label_index
                return True
        return False
    for label_index in range(len(positives)):
        match(label_index, set())
    matches = [{'prediction': i, 'positive': label_index} for i, label_index in sorted(owners.items())]
    negative_matches = [dict(prediction=i, negative=j, type=candidate['product_type'])
                        for i, candidate in enumerate(predictions)
                        for j, negative in enumerate(labels.get('negativeSpans', []))
                        if candidate['product_type'] in negative['forbiddenTypes']
                        and same_take(candidate, _span(negative))]
    unexpected = []
    for i, candidate in enumerate(predictions):
        for j in range(i + 1, len(predictions)):
            if not same_take(candidate, predictions[j]):
                continue
            if i in owners and j in owners and same_take(_span(positives[owners[i]]), _span(positives[owners[j]])):
                continue
            unexpected.append(dict(predictions=[i, j], types=[candidate['product_type'], predictions[j]['product_type']]))
    exact = sum(predictions[i]['start_index'] == positives[j]['start']
                and predictions[i]['end_index'] == positives[j]['end'] for i, j in owners.items())
    per_type = {}
    for kind in sorted({p['type'] for p in positives} | {p['product_type'] for p in predictions}):
        expected = sum(p['type'] == kind for p in positives)
        found = sum(positives[j]['type'] == kind for j in owners.values())
        per_type[kind] = dict(expected=expected, matched=found,
                              predicted=sum(p['product_type'] == kind for p in predictions),
                              recall=found / expected if expected else None)
    return dict(expected=len(positives), predicted=len(predictions), matched=len(matches),
                positive_take_recall=len(matches) / len(positives) if positives else 1.0,
                exact_span_matches=exact, matches=matches,
                missed_positives=sorted(set(range(len(positives))) - set(owners.values())),
                unmatched_predictions=sorted(set(range(len(predictions))) - set(owners)),
                negative_span_matches=negative_matches, unexpected_overlaps=unexpected,
                per_type=per_type)


def run_editorial_eval(dataset_dir=DEFAULT_DATASET, *, mode='cached', model='gpt-4o',
                       cache_dir=DEFAULT_CACHE, output_dir=None,
                       discovery_version=CONFIGURED_DISCOVERY_VERSION, llm=None) -> dict:
    if mode not in ('cached', 'live'):
        raise ValueError('mode must be cached or live')
    request = build_request(dataset_dir, model=model, discovery_version=discovery_version)
    labels = json.loads((Path(dataset_dir) / 'labels.json').read_text())
    client = llm if llm is not None else CachingLLMClient(
        str(Path(cache_dir) / discovery_version),
        inner=live_client_for(model) if mode == 'live' else None, model=model,
        prompt_version=discovery_version, product_spec_version=request['options']['product_spec_version'],
        window_params={'window': 130, 'step': 110})
    # A fresh temporary journal in cached mode exercises every replayed response
    # and validator instead of trusting a precomputed candidate checkpoint.
    with tempfile.TemporaryDirectory(prefix='editorial-eval-') as temporary:
        directory = Path(output_dir) if output_dir is not None else Path(temporary)
        directory.mkdir(parents=True, exist_ok=True)
        journal = RunJournal(directory / 'journal', request_identity=request_identity(request),
                             immutable_request=immutable_request(request))
        (directory / 'request.json').write_text(json.dumps(request, indent=2) + '\n')
        result = run_configured_suggest(request, client, journal, lambda event: None)
        if result['status'] != 'ready':
            raise RuntimeError('editorial evaluation did not complete: ' + json.dumps(result['failed_batches']))
        metrics = editorial_metrics(result['suggestions'], labels)
        report = dict(dataset=Path(dataset_dir).name, mode=mode, model=model,
                      discovery_prompt_version=discovery_version, run_id=request['run_id'],
                      synthetic=labels.get('synthetic', False), metrics=metrics,
                      quality_pass=(metrics['matched'] == metrics['expected']
                                    and metrics['exact_span_matches'] == metrics['expected']
                                    and not metrics['unmatched_predictions']
                                    and not metrics['negative_span_matches']
                                    and not metrics['unexpected_overlaps']),
                      result=result)
        (directory / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        (directory / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
        return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mode', choices=['cached', 'live'], default='cached')
    parser.add_argument('--model', default='gpt-4o')
    parser.add_argument('--dataset', default=str(DEFAULT_DATASET))
    parser.add_argument('--cache-dir', default=str(DEFAULT_CACHE))
    parser.add_argument('--output-dir', help='Retain request, validated journal, result and report here')
    parser.add_argument('--discovery-version', default=CONFIGURED_DISCOVERY_VERSION)
    parser.add_argument('--json', action='store_true')
    args = parser.parse_args(argv)
    report = run_editorial_eval(args.dataset, mode=args.mode, model=args.model,
                                cache_dir=args.cache_dir, output_dir=args.output_dir,
                                discovery_version=args.discovery_version)
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"{report['dataset']}: {args.mode}, {args.model}, {args.discovery_version}")
        print(json.dumps(report['metrics'], indent=2))
        print('Quality gate: ' + ('PASS' if report['quality_pass'] else 'FAIL'))
        if report['synthetic']:
            print('Synthetic evidence only, including post-commercial transitions; not production Claude validation.')
    return 0 if report['quality_pass'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
