"""Disk cache for LLM calls: deterministic keys, replay, no-network guarantee."""

import pytest

from cut_suggester.cache import CacheMiss, CachingLLMClient
from cut_suggester.llm import LLMResponse


class _FakeLLM:
    """Records prompts and returns a canned answer; stands in for the network."""

    def __init__(self):
        self.calls = []

    def complete(self, prompt, *, purpose=""):
        self.calls.append((prompt, purpose))
        return LLMResponse(text=f"answer:{len(self.calls)}", usage={}, model="fake")


def _client(cache_dir, inner=None, **over):
    ctx = dict(
        model="gpt-4o", prompt_version="v1", product_spec_version="v1",
        window_params={"window": 130, "step": 110},
    )
    ctx.update(over)
    return CachingLLMClient(str(cache_dir), inner=inner, **ctx)


def test_cached_mode_with_no_inner_raises_on_miss(tmp_path):
    client = _client(tmp_path, inner=None)
    with pytest.raises(CacheMiss):
        client.complete("hello")


def test_live_mode_writes_through_and_replays_without_network(tmp_path):
    inner = _FakeLLM()
    live = _client(tmp_path, inner=inner)
    r1 = live.complete("partition window 0", purpose="partition")
    assert r1.text == "answer:1"
    assert len(inner.calls) == 1

    # A fresh cached-only client over the same dir replays with no inner call.
    replay = _client(tmp_path, inner=None)
    r2 = replay.complete("partition window 0", purpose="partition")
    assert r2.text == "answer:1"
    assert r2.cached is True
    assert len(inner.calls) == 1  # inner was not called again


def test_key_includes_model_and_pins_and_prompt(tmp_path):
    inner = _FakeLLM()
    live = _client(tmp_path, inner=inner)
    live.complete("same prompt")
    # Changing any pin or the prompt is a cache miss (a different call).
    for over in (
        {"model": "claude-sonnet-5"},
        {"prompt_version": "v2"},
        {"product_spec_version": "v2"},
        {"window_params": {"window": 100, "step": 100}},
    ):
        assert not _client(tmp_path, inner=None, **over)._has("same prompt")
    assert not _client(tmp_path, inner=None)._has("different prompt")
    assert _client(tmp_path, inner=None)._has("same prompt")  # unchanged -> hit
