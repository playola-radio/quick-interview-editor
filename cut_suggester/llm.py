"""Provider-agnostic LLM client abstraction.

The network call is a single injectable seam. `LLMClient` is the protocol;
`OpenAIClient` (raw HTTP, the current eval baseline via $OPENAI_KEY -> gpt-4o)
and `AnthropicClient` (the official SDK, default production `claude-sonnet-5`)
are the live impls. Tests and the cached eval never touch the network — they use
fixtures/replay through the cache.
"""

from __future__ import annotations

import json
import os
import urllib.request
from dataclasses import dataclass, field
from typing import Protocol


@dataclass
class LLMResponse:
    text: str
    usage: dict = field(default_factory=dict)
    model: str = ""
    cached: bool = False


class LLMClient(Protocol):
    def complete(self, prompt: str, *, purpose: str = "") -> LLMResponse: ...


def _provider_for(model: str) -> str:
    m = model.lower()
    if m.startswith(("gpt-", "o1", "o3", "o4")):
        return "openai"
    if m.startswith("claude") or "sonnet" in m or "opus" in m or "haiku" in m or "fable" in m:
        return "anthropic"
    raise ValueError(f"cannot infer provider for model {model!r}")


class OpenAIClient:
    """Chat Completions over raw HTTP (matches the spike; no SDK dependency)."""

    def __init__(self, model: str, *, timeout: int = 180):
        self.model = model
        self.timeout = timeout

    def complete(self, prompt: str, *, purpose: str = "") -> LLMResponse:
        key = os.environ.get("OPENAI_KEY") or os.environ.get("OPENAI_API_KEY")
        if not key:
            raise RuntimeError("OPENAI_KEY is not set")
        body = json.dumps(
            {
                "model": self.model,
                "messages": [{"role": "user", "content": prompt}],
                "temperature": 0,
                "response_format": {"type": "json_object"},
            }
        ).encode()
        req = urllib.request.Request(
            "https://api.openai.com/v1/chat/completions",
            data=body,
            headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=self.timeout) as r:
            resp = json.load(r)
        choice = resp["choices"][0]
        finish_reason = choice.get("finish_reason")
        text = choice["message"]["content"]
        if finish_reason == "length":
            raise RuntimeError(
                f"OpenAI hit the output token limit for {purpose or 'prompt'} before completing JSON"
            )
        if not text.strip():
            raise RuntimeError(f"OpenAI returned an empty response for {purpose or 'prompt'}")
        return LLMResponse(
            text=text,
            usage={**resp.get("usage", {}), "finish_reason": finish_reason},
            model=self.model,
        )


class AnthropicClient:
    """Anthropic Messages API via the official SDK.

    JSON is requested via the system prompt (the task is a simple structured
    extraction). The SDK is imported lazily so the OpenAI baseline and the
    offline tests do not require it.
    """

    _JSON_SYSTEM = "You are a precise assistant. Reply with a single strict JSON object and nothing else."

    def __init__(self, model: str, *, max_tokens: int = 16000):
        self.model = model
        self.max_tokens = max_tokens

    def complete(self, prompt: str, *, purpose: str = "") -> LLMResponse:
        import anthropic  # lazy: only needed for the Anthropic live path

        client = anthropic.Anthropic()
        msg = client.messages.create(
            model=self.model,
            max_tokens=self.max_tokens,
            # This is strict JSON extraction, not a reasoning task. On Claude 5
            # models adaptive thinking is ON by default and shares the max_tokens
            # budget with the answer text, so a large classify prompt can spend the
            # whole budget on hidden thinking and return zero text. Disable it so the
            # budget is the JSON output.
            thinking={"type": "disabled"},
            system=self._JSON_SYSTEM,
            messages=[{"role": "user", "content": prompt}],
        )
        text = "".join(b.text for b in msg.content if getattr(b, "type", None) == "text")
        stop_reason = getattr(msg, "stop_reason", None)
        usage = {}
        if getattr(msg, "usage", None) is not None:
            usage = {
                "prompt_tokens": msg.usage.input_tokens,
                "completion_tokens": msg.usage.output_tokens,
                "stop_reason": stop_reason,
            }
        if stop_reason == "max_tokens":
            raise RuntimeError(
                f"Anthropic hit max_tokens={self.max_tokens} for {purpose or 'prompt'} "
                "before completing JSON"
            )
        if not text.strip():
            raise RuntimeError(
                f"Anthropic returned an empty response for {purpose or 'prompt'} "
                f"(stop_reason={stop_reason!r})"
            )
        return LLMResponse(text=_strip_json_fence(text), usage=usage, model=self.model)


def _strip_json_fence(text: str) -> str:
    t = text.strip()
    if t.startswith("```"):
        t = t.split("\n", 1)[1] if "\n" in t else t
        if t.endswith("```"):
            t = t[: t.rfind("```")]
    return t.strip()


def live_client_for(model: str) -> LLMClient:
    provider = _provider_for(model)
    return OpenAIClient(model) if provider == "openai" else AnthropicClient(model)
