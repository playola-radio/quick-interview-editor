"""Disk cache for LLM calls.

`temperature:0` is not deterministic, so raw responses are cached to disk keyed
by hash(model, promptVersion, productSpecVersion, window params, prompt). This
makes cached-mode CI reproducible with no network. In cached mode (`inner=None`)
a miss raises `CacheMiss` rather than reaching for the network.
"""

from __future__ import annotations

import hashlib
import json
import os
import tempfile

from .llm import LLMClient, LLMResponse


class CacheMiss(Exception):
    """Raised when a cached-only client has no entry for a prompt."""


class CachingLLMClient:
    def __init__(
        self,
        cache_dir: str,
        *,
        inner: LLMClient | None = None,
        model: str,
        prompt_version: str,
        product_spec_version: str,
        window_params: dict,
        refresh: bool = False,
    ):
        self.cache_dir = cache_dir
        self.inner = inner
        self.model = model
        self.prompt_version = prompt_version
        self.product_spec_version = product_spec_version
        self.window_params = window_params
        # When True, ignore any existing cache entry and recompute through `inner`,
        # then overwrite. Lets a caller force fresh results after a prompt/model
        # change without deleting the cache dir. Requires `inner` (a live client).
        self.refresh = refresh

    def _key(self, prompt: str) -> str:
        payload = {
            "model": self.model,
            "prompt_version": self.prompt_version,
            "product_spec_version": self.product_spec_version,
            "window_params": self.window_params,
            "prompt": prompt,
        }
        blob = json.dumps(payload, sort_keys=True, ensure_ascii=True)
        return hashlib.sha256(blob.encode()).hexdigest()

    def _path(self, prompt: str) -> str:
        return os.path.join(self.cache_dir, f"{self._key(prompt)}.json")

    def _has(self, prompt: str) -> bool:
        return os.path.exists(self._path(prompt))

    def complete(self, prompt: str, *, purpose: str = "") -> LLMResponse:
        path = self._path(prompt)
        if os.path.exists(path) and not self.refresh:
            with open(path) as f:
                entry = json.load(f)
            r = entry["response"]
            text = r["text"]
            if text.strip():
                return LLMResponse(
                    text=text, usage=r.get("usage", {}), model=r.get("model", ""), cached=True)
            if self.inner is None:
                raise CacheMiss(
                    f"cached response for {purpose or 'prompt'} was empty "
                    f"(model={self.model}, prompt_version={self.prompt_version}); "
                    "rerun live with --refresh to replace the cache entry"
                )
            # Old app versions could cache an empty provider response, which then
            # replayed forever as "no suggestions." In live mode, treat that as a
            # poisoned cache entry and recompute through the provider below.

        if self.inner is None:
            raise CacheMiss(
                f"no cached response for {purpose or 'prompt'} "
                f"(model={self.model}, prompt_version={self.prompt_version}); "
                "run the eval in live mode to populate the cache"
            )

        resp = self.inner.complete(prompt, purpose=purpose)
        if not resp.text.strip():
            raise RuntimeError(
                f"LLM returned an empty response for {purpose or 'prompt'}; not caching it"
            )
        os.makedirs(self.cache_dir, exist_ok=True)
        entry = {
            "model": self.model,
            "prompt_version": self.prompt_version,
            "product_spec_version": self.product_spec_version,
            "window_params": self.window_params,
            "purpose": purpose,
            "prompt": prompt,
            "response": {"text": resp.text, "usage": resp.usage, "model": resp.model},
        }
        # Unique temp file per writer: a shared "<path>.tmp" lets concurrent
        # writers of the same key clobber each other's temp (FileNotFoundError on
        # os.replace, or a torn read). mkstemp gives each writer its own file;
        # os.replace onto the final path is atomic.
        fd, tmp = tempfile.mkstemp(dir=self.cache_dir, suffix=".tmp")
        try:
            with os.fdopen(fd, "w") as f:
                json.dump(entry, f, indent=1, sort_keys=True)
            os.replace(tmp, path)
        finally:
            if os.path.exists(tmp):
                os.remove(tmp)
        return resp
