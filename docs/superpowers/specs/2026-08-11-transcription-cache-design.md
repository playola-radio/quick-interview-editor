# Overridable Transcription Cache — Design

**Date:** 2026-08-11
**Branch:** `briankeane/whispersync-cache`
**Status:** Approved (design), pending implementation plan

## Problem

Importing a `.wav` runs the Python WhisperX engine (forced alignment) as a
subprocess. It takes several minutes. During iteration the same file gets
re-dragged repeatedly just to check whether a small change worked, paying the
full transcription cost each time.

We want an **overridable, on-disk cache** so that re-importing an identical file
is instant, while still being able to force a fresh run and to auto-invalidate
when the engine itself changes.

## Requirements

- **Instant re-import** of a byte-identical source file.
- **Auto-invalidate on engine change** — editing the transcription engine makes
  the cache miss automatically, with no manual step (requirement "D").
- **Manual force-refresh** — an explicit "re-import ignoring the cache" action
  for the cases auto-invalidation can't cover (requirement "A").
- **Manual clear** — wipe the whole cache on demand.
- Unbounded size for v1 (single-user dev/personal tool), but growth must stay
  **visible**.

## Non-goals

- No automatic LRU / size-cap eviction in v1 (documented growth + a labeled
  clear action instead).
- No change to the Python engine's own behavior or output contract.
- No `⌥`-drop force-refresh gesture — force-refresh is menu + keyboard shortcut
  only, to keep plain drag behavior predictable.

## Existing building blocks (reused, not rebuilt)

- `SourceFingerprint.make(for:)` — already computes `"sha256:<hex of file bytes>"`
  off the main actor in `SongTabModel.startTranscription`, before the engine
  runs. This is the source half of the cache key.
- `EditPlan` (`Models/EditPlan.swift`) — `Codable`, already round-trips the
  engine JSON. It is the heavy transcript payload and can be persisted verbatim.
- `EngineClient` (`Core/EngineClient.swift`) — the `swift-dependencies` subprocess
  boundary. `transcribe(url) -> AsyncThrowingStream<EngineEvent, Error>` yields
  `.progress(...)` then `.completed(TranscriptionResult{editPlan, canonicalAudioURL})`.
- `@Shared` fileStorage sidecar pattern (`State/ProjectStore.swift`,
  `Models/ProjectState.swift`) — precedent for a fingerprint-keyed persistent
  store under `Application Support/QuickInterviewEditor/`.
- `CanonicalAudioStore` — copies the engine's `<stem>.plan.aiff` out of the
  deleted scratch dir into a **throwaway per-job UUID** dir, pruned at launch and
  on tab close. Deliberately **not** reused for cache storage (see §3).

## Architecture

### Overview

Insert a new dependency **between** the page model and the raw engine:

```
SongTabModel
   │  transcription.transcribe(url, fingerprint, policy)
   ▼
TranscriptionClient           ← new: cache orchestration
   ├─ TranscriptCacheClient   ← new: lookup / store / clear / size
   └─ EngineClient            ← unchanged: pure subprocess boundary
```

`EngineClient` stays exactly as-is. `SongTabModel` changes minimally: it calls
the new `TranscriptionClient` instead of `EngineClient` directly, and it owns
only the **policy** decision (normal vs. force-refresh), never persistence.

### 1. Cache key

```
key = SHA256( sourceSha256 + "\n" + engineFingerprint + "\n" + cacheSchemaVersion )
```

- **`sourceSha256`** — the existing `SourceFingerprint`, used **only when it is a
  `sha256:` fingerprint**. If `SourceFingerprint` falls back to `path:` (bytes
  unreadable), the cache is **bypassed entirely** — no lookup, no store, always
  transcribe. (A `path:`-keyed entry could serve a stale transcript for a
  different file that later occupies the same path.)
- **`engineFingerprint`** — content hash of the engine, **memoized once per app
  launch** (not recomputed per import):
  - **Dev** (runs `python -m logic_markers.cli`): hash of `logic_markers/**/*.py`
    **plus the dependency pin file** (e.g. `requirements*.txt` / lock), so a
    WhisperX or dependency bump also invalidates.
  - **Packaged** (frozen `logic-markers-engine`): **content hash of the binary**,
    not size+mtime (mtime can false-hit).
- **`cacheSchemaVersion`** — a constant bumped if the on-disk cache format changes.

Design bias: **over-invalidation is safe** (worst case = one unnecessary
re-transcribe); **under-invalidation is the only real hazard** (stale result), so
the engine fingerprint errs broad.

### 2. `TranscriptionClient` (new dependency)

Same stream shape as the engine, plus a policy:

```swift
enum CachePolicy { case useCache, forceFresh }

struct TranscriptionClient: Sendable {
  var transcribe: @Sendable (_ source: URL,
                             _ fingerprint: String,
                             _ policy: CachePolicy)
                             -> AsyncThrowingStream<EngineEvent, Error>
}
```

- **`.useCache` + hit:** synthesize a `.completed(TranscriptionResult{editPlan,
  canonicalAudioURL})` from disk — no subprocess, no progress events (or a single
  synthetic "loaded from cache" progress tick).
- **`.useCache` + miss**, or **`.forceFresh`:** stream the real `EngineClient`
  transcribe; on `.completed`, **store** the result in the cache (atomically —
  §3) before forwarding the terminal event.
- **Bypass** (non-`sha256:` fingerprint): forward the engine stream unchanged,
  never touch the cache.

`liveValue` wraps `EngineClient` + `TranscriptCacheClient`. `testValue` returns a
configurable stream so page tests exercise hit / miss / force with **zero disk and
no subprocess**.

### 3. `TranscriptCacheClient` (new dependency) + storage layout

```swift
struct CachedTranscription: Sendable {
  var editPlan: EditPlan
  var canonicalAudioURL: URL   // cache-owned copy
}

struct TranscriptCacheClient: Sendable {
  var lookup: @Sendable (_ key: String) -> CachedTranscription?
  var store:  @Sendable (_ key: String, _ plan: EditPlan, _ canonicalAudioURL: URL) throws -> CachedTranscription
  var clear:  @Sendable () throws -> Void
  var totalSize: @Sendable () -> Int64
}
```

**Layout:** one directory per entry under
`Application Support/QuickInterviewEditor/TranscriptCache/<key>/`, containing:

- `plan.json` — the serialized `EditPlan`
- `canonical.aiff` — the cache-owned canonical audio
- `manifest.json` — cache schema version, source + engine fingerprints, file sizes

**Atomic store** (prevents a half-written entry from being read as a hit after a
crash):

1. Write into a temp dir `TranscriptCache/<key>.tmp.<uuid>/`.
2. Write `plan.json`.
3. Copy `canonical.aiff` into the temp dir.
4. Write `manifest.json` **last**.
5. Atomically rename the temp dir into place at `<key>/` (replacing any existing
   entry — this is also how force-refresh overwrites: build the new entry fully,
   then swap; never delete the old entry before the new one is complete).

**Lookup** counts as a hit **only if** `manifest.json` exists and both payload
files are present. Anything else is a miss; stray `*.tmp.*` dirs are cleaned
opportunistically.

**AIFF ownership:** the cache owns its own `canonical.aiff` copy and does **not**
route through `CanonicalAudioStore` (which prunes on launch and tab close and
would delete the persistent cache). On a cache hit, `EditorModel` receives the
cache-owned AIFF URL directly.

- `EditorModel.discardCanonicalAudio()` calls `CanonicalAudioStore.remove(...)`,
  which is guarded to only delete inside the canonical-store base — so it will
  **not** delete a cache-owned AIFF. Good, but call this ownership out explicitly
  in code comments.
- **Edge case:** "Clear transcription cache" must not yank an AIFF that an open
  editor tab is currently reading. v1 handling: clearing is a user-initiated,
  explicit action; document that it affects future imports and that already-open
  tabs keep working against their in-use file until closed. (If this proves
  fragile, revisit — but no auto-clear runs behind the user's back.)

**Stale path note:** `EditPlan.source.path` may hold the original or scratch
path. On a cache hit, nothing downstream may rely on `source.path` being a live
file — the usable audio URL is always the cache-owned `canonicalAudioURL` handed
to `EditorModel`.

### 4. User controls

- **Force refresh (requirement A)** — a "Re-import (Ignore Cache)" menu item +
  keyboard shortcut. Runs the current source with `.forceFresh`; the fresh result
  atomically replaces the cache entry for that key. Menu + shortcut only; no
  drag-gesture variant.
- **Clear cache** — a "Clear Transcription Cache" menu item, **labeled with the
  current size** (e.g. "Clear Transcription Cache (2.3 GB)") so unbounded growth
  stays visible. Wipes `TranscriptCache/`. No automatic eviction in v1.

## Data flow

**Import (normal):**
1. `SongTabModel.startTranscription` computes `SourceFingerprint` (as today).
2. Calls `transcription.transcribe(url, fingerprint, .useCache)`.
3. `TranscriptionClient` computes the key (bypass if fingerprint isn't `sha256:`).
4. **Hit** → synthesize `.completed` from disk → `SongTabModel` builds
   `EditorModel` from cached `EditPlan` + cache-owned AIFF → phase `.loaded`.
   **Miss** → stream `EngineClient` → on `.completed`, atomic store → forward.

**Force refresh:** same, with `.forceFresh` (skip lookup, always transcribe,
overwrite entry).

## Testing

- `TranscriptCacheClient`: focused tests against a temp dir — store→lookup hit,
  atomic store leaves no partial entry, missing manifest = miss, `totalSize`,
  `clear`.
- `TranscriptionClient`: hit path (no engine call), miss path (engine called +
  stored), force path (engine called even with a warm entry), bypass path
  (non-`sha256:` fingerprint never touches cache). Mock `EngineClient` +
  in-memory / temp cache.
- `SongTabModel`: existing tests migrate to mock `TranscriptionClient`; assert it
  passes the right `CachePolicy` for normal vs. force-refresh actions and reaches
  `.loaded` on a synthesized cache hit with no engine invocation.
- Reuse bundled `edit-plan.json` fixtures; no real audio, no subprocess.

## Open items / follow-ups

- LRU / size-cap eviction (deferred; unbounded + labeled clear for v1).
- If the "clear while a tab holds an open cached AIFF" edge proves fragile,
  add a guard that skips (or defers) deletion of in-use files.
