"""Provider-agnostic LLM client abstraction.

The network call is a single injectable seam. `LLMClient` is the protocol;
`OpenAIClient` (raw HTTP, the current eval baseline via $OPENAI_KEY -> gpt-4o)
and `AnthropicClient` (the official SDK, default production `claude-sonnet-5`)
are the live impls. Tests and the cached eval never touch the network — they use
fixtures/replay through the cache.
"""

from __future__ import annotations

import json
import math
import os
import re
import urllib.error
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


_RETRYABLE_CATEGORIES = frozenset(
    {"rate_limit", "overloaded", "network", "timeout", "server", "bad_response", "unknown"}
)
_CREDIT_WORDS = re.compile(r"\b(credits?|billing|balance|quota)\b")
_CREDIT_ERROR_KINDS = frozenset({"billing_error", "insufficient_quota"})


class LLMError(RuntimeError):
    """A provider failure normalized into a category the app can explain.

    ``retryable`` means the same request may succeed unchanged; it is not the
    app's Resume-button policy.
    """

    def __init__(
        self, category: str, message: str, *, status_code: int | None = None,
        request_id: str | None = None, retry_after: float | None = None,
        error_type: str | None = None,
    ):
        super().__init__(message)
        self.category = category
        self.message = message
        self.status_code = status_code
        self.request_id = request_id
        self.retry_after = retry_after
        self.error_type = error_type or type(self).__name__
        self.retryable = category in _RETRYABLE_CATEGORIES


def failure_record(exc: BaseException) -> dict:
    """The safe, persisted facts about one failed provider request."""
    if isinstance(exc, LLMError):
        return {
            "category": exc.category, "message": exc.message, "status_code": exc.status_code,
            "request_id": exc.request_id, "retry_after": exc.retry_after,
            "retryable": exc.retryable, "error_type": exc.error_type,
        }
    # Parser and validation errors (all ValueError subclasses) mean the provider
    # answered with something the app could not use.
    category = "bad_response" if isinstance(exc, ValueError) else "unknown"
    return {
        "category": category, "message": str(exc) or type(exc).__name__, "status_code": None,
        "request_id": None, "retry_after": None, "retryable": True,
        "error_type": type(exc).__name__,
    }


def json_error_detail(exc: Exception) -> str:
    """Where a provider response stopped being JSON, without echoing its content."""
    if isinstance(exc, json.JSONDecodeError):
        return f"{exc.msg} at char {exc.pos}"
    return str(exc)


def _status_error(status: int, body: object, headers, request_id: str | None,
                  fallback: str, error_type: str) -> LLMError:
    error = body.get("error") if isinstance(body, dict) else None
    error = error if isinstance(error, dict) else {}
    message = error.get("message") if isinstance(error.get("message"), str) else fallback
    kinds = {error.get("type"), error.get("code")}
    if status == 401:
        category = "auth"
    elif kinds & _CREDIT_ERROR_KINDS or (
        status == 400 and _CREDIT_WORDS.search(message.lower())
    ):
        category = "credits"
    elif status == 429:
        category = "rate_limit"
    elif status == 529 or "overloaded_error" in kinds:
        category = "overloaded"
    elif status >= 500:
        category = "server"
    else:
        category = "bad_request"
    return LLMError(category, message, status_code=status, request_id=request_id,
                    retry_after=_retry_after(headers), error_type=error_type)


def _retry_after(headers) -> float | None:
    try:
        seconds = float(headers.get("retry-after"))
    except (AttributeError, TypeError, ValueError):
        return None
    if not math.isfinite(seconds) or seconds < 0:
        return None
    return int(seconds) if seconds.is_integer() else seconds


def _with_root_cause(message: str, exc: BaseException) -> str:
    """SDK connection errors only say "Connection error."; name the real cause."""
    root, cause, seen = None, exc.__cause__ or exc.__context__, set()
    while cause is not None and id(cause) not in seen:
        seen.add(id(cause))
        if str(cause):
            root = cause
        cause = cause.__cause__ or cause.__context__
    if root is None:
        return message
    return f"{message} Cause: {type(root).__name__}: {root}"


def _provider_for(model: str) -> str:
    m = model.lower()
    if m.startswith(("gpt-", "o1", "o3", "o4")):
        return "openai"
    if m.startswith("claude") or "sonnet" in m or "opus" in m or "haiku" in m or "fable" in m:
        return "anthropic"
    raise ValueError(f"cannot infer provider for model {model!r}")


def _supports_disabled_thinking(model: str) -> bool:
    """Whether ``thinking={"type": "disabled"}`` is accepted by ``model``.

    Claude Fable 5 and Mythos 5 always think and reject a disabled-thinking
    request with HTTP 400, so the parameter must be omitted for them. Every other
    current Claude model accepts it (Opus 5 only rejects it above ``high`` effort,
    which we never set).
    """
    m = model.lower()
    return "fable" not in m and "mythos" not in m


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
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as r:
                resp = json.load(r)
        except urllib.error.HTTPError as exc:
            try:
                body = json.loads(exc.read().decode() or "null")
            except (OSError, ValueError):
                body = None
            headers = exc.headers
            raise _status_error(
                exc.code, body, headers, headers.get("x-request-id") if headers else None,
                f"HTTP {exc.code}: {exc.reason}", type(exc).__name__,
            ) from exc
        except urllib.error.URLError as exc:
            reason = exc.reason
            category = "timeout" if isinstance(reason, TimeoutError) else "network"
            cause = f"{type(reason).__name__}: {reason}" if isinstance(reason, BaseException) else reason
            raise LLMError(category, f"Connection error. Cause: {cause}",
                           error_type=type(exc).__name__) from exc
        except TimeoutError as exc:
            raise LLMError("timeout", f"Request timed out: {exc}",
                           error_type=type(exc).__name__) from exc
        choices = resp.get("choices") if isinstance(resp, dict) else None
        choice = choices[0] if isinstance(choices, list) and choices else None
        message = choice.get("message") if isinstance(choice, dict) else None
        text = message.get("content") if isinstance(message, dict) else None
        if not isinstance(text, str):
            raise LLMError("bad_response", f"OpenAI returned no message content for {purpose or 'prompt'}")
        finish_reason = choice.get("finish_reason")
        if finish_reason == "length":
            raise LLMError(
                "bad_response",
                f"OpenAI hit the output token limit for {purpose or 'prompt'} before completing JSON",
            )
        if not text.strip():
            raise LLMError("bad_response", f"OpenAI returned an empty response for {purpose or 'prompt'}")
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
        create_kwargs: dict = {
            "model": self.model,
            "max_tokens": self.max_tokens,
            "system": self._JSON_SYSTEM,
            "messages": [{"role": "user", "content": prompt}],
        }
        # This is strict JSON extraction, not a reasoning task. On Claude 5 models
        # adaptive thinking is ON by default and shares the max_tokens budget with
        # the answer text, so a large classify prompt can spend the whole budget on
        # hidden thinking and return zero text. Disable thinking where the model
        # supports it. Fable 5 / Mythos 5 always think and reject
        # thinking={"type": "disabled"} with a 400, so we leave it unset there and
        # rely on the generous max_tokens budget (and the max_tokens guard below).
        if _supports_disabled_thinking(self.model):
            create_kwargs["thinking"] = {"type": "disabled"}
        try:
            msg = client.messages.create(**create_kwargs)
        except anthropic.APIConnectionError as exc:
            category = "timeout" if isinstance(exc, anthropic.APITimeoutError) else "network"
            raise LLMError(category, _with_root_cause(exc.message, exc),
                           error_type=type(exc).__name__) from exc
        except anthropic.APIStatusError as exc:
            raise _status_error(exc.status_code, exc.body, exc.response.headers, exc.request_id,
                                exc.message, type(exc).__name__) from exc
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
            raise LLMError(
                "bad_response",
                f"Anthropic hit max_tokens={self.max_tokens} for {purpose or 'prompt'} "
                "before completing JSON"
            )
        if not text.strip():
            raise LLMError(
                "bad_response",
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
