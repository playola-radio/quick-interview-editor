"""Resolve successfully nameless Intros without consuming naming failures as evidence."""

from __future__ import annotations

import uuid

from .configured_discovery import _candidate_id, _overlap, _span_length, _preferred_same_type, same_take

QUALIFICATION_FIELD_IDS = frozenset(('artist-name', 'song-title'))


def qualify_intros(candidates: list[dict], evidence: dict, configuration: dict, run_id: str) -> list[dict]:
    """Prefer existing tuned Spotlights, then convert complete in-bounds discoveries.

    Evidence contains only fully validated successful requests. Deleted definitions,
    failed calls, and oversized evidence never count as explicit missing values.
    """
    available = {field['id'] for field in configuration['fields']}
    spotlight_configured = any(item['id'] == 'spotlight' for item in configuration['types'])
    spotlights = [item for item in candidates if item['product_type'] == 'spotlight']
    surviving = []
    converted = []
    for candidate in candidates:
        values = evidence.get(candidate['candidate_id'], {})
        disqualified = (
            candidate['product_type'] == 'intro'
            and QUALIFICATION_FIELD_IDS <= available
            and QUALIFICATION_FIELD_IDS <= values.keys()
            and all(values[field] is None for field in QUALIFICATION_FIELD_IDS)
        )
        if not disqualified:
            surviving.append(candidate)
        elif spotlight_configured and not any(
            _overlap(candidate, item) / _span_length(candidate) >= 0.8 for item in spotlights
        ):
            if 15 <= candidate['duration_sec'] <= 240:
                fallback = {**candidate, 'product_type': 'spotlight', 'fields': {},
                            'song': None, 'song_verified': False}
                fallback['candidate_id'] = _candidate_id(uuid.UUID(run_id), fallback)
                converted.append(fallback)

    intros = _preferred_same_type([item for item in surviving if item['product_type'] == 'intro'])
    # The tuned pass already resolved its own selections. Deduplicate only the
    # additions and tuned candidates that overlap them, preserving unrelated cuts.
    affected = [item for item in spotlights if any(same_take(item, added) for added in converted)]
    unaffected = [item for item in spotlights if not any(same_take(item, added) for added in converted)]
    spotlights = unaffected + _preferred_same_type(affected + converted)
    spotlights = [item for item in spotlights
                  if not any(_overlap(item, intro) / _span_length(item) >= 0.8 for intro in intros)]
    other = [item for item in surviving if item['product_type'] not in ('intro', 'spotlight')]
    return sorted(intros + spotlights + other,
                  key=lambda item: (item['start_index'], item['end_index'], item['product_type']))
