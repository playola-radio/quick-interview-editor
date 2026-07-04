# Implementation Plan: transcript-driven chunking

Spec: `docs/superpowers/specs/2026-07-03-transcript-chunking-design.md`

## Stage 1: Word/segment model + `transcript` command
**Goal**: `logic-markers transcript song.m4a` writes the `[n]`-tagged transcript and caches the full word list (with end times + segment/word ids).
**Success**: transcript file matches the spec format; cache has per-word start/end/id and per-segment word ranges.
**Tests**: transcript rendering from a synthetic segment list; cache round-trip.
**Status**: Complete

## Stage 2: Silence detection (`silence.py`)
**Goal**: adaptive silence regions over a mono PCM array.
**Success**: on synthetic tone+gap signals at varied noise floors, detected regions match known gaps within tolerance.
**Tests**: adaptive threshold from noise floor; window/hop; min-silence filtering; no-silence case.
**Status**: Complete

## Stage 3: Edit-file parse + alignment (`editplan.py`, part 1)
**Goal**: parse edited transcript into blocks; resolve each to a word-index range + content time span using stable IDs (+ constrained intra-line fuzzy trim).
**Success**: repeated-phrase transcript disambiguates correctly; deletes/splits/intra-line trims map right; missing-tag fallback warns.
**Tests**: the failure cases from the spec.
**Status**: Complete

## Stage 4: Boundary snapping + edit-plan.json (`editplan.py`, part 2)
**Goal**: snap each block's boundaries outward to silence edges; emit versioned edit-plan.json with statuses/candidates.
**Success**: outward snap, no-clip guarantee, no-silence fallback all hold; JSON validates against the documented shape.
**Tests**: word spans vs synthetic silence maps.
**Status**: Complete

## Stage 5: Slicer + AIFF output (`slicer.py`)
**Goal**: sample-accurate slice per segment; markers re-based to slice start; write `song.N.aiff`.
**Success**: slice offsets and re-based marker positions correct on a synthetic AIFF.
**Tests**: slicing + marker rebasing.
**Status**: Not Started

## Stage 6: `cut` command wiring + real-file integration
**Goal**: end-to-end `cut` on the real clip.
**Success**: N valid AIFFs (afinfo), markers present/re-based, edit-plan.json written; manual Logic check.
**Tests**: integration test.
**Status**: Not Started
