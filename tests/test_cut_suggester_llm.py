"""AnthropicClient request construction: thinking is gated by model, guards fire."""

import sys
import types

import pytest

from cut_suggester.llm import AnthropicClient, _supports_disabled_thinking


class _FakeMessage:
    def __init__(self, text, *, stop_reason="end_turn", output_tokens=10):
        self.content = [types.SimpleNamespace(type="text", text=text)]
        self.stop_reason = stop_reason
        self.usage = types.SimpleNamespace(input_tokens=5, output_tokens=output_tokens)


class _FakeMessages:
    def __init__(self, message):
        self.message = message
        self.last_kwargs = None

    def create(self, **kwargs):
        self.last_kwargs = kwargs
        return self.message


class _FakeAnthropic:
    """Stands in for the `anthropic` SDK module; records the create() kwargs."""

    def __init__(self, message):
        self.messages = _FakeMessages(message)

    def Anthropic(self):  # noqa: N802 - mirrors anthropic.Anthropic()
        return self


@pytest.fixture
def fake_anthropic(monkeypatch):
    def install(message):
        client = _FakeAnthropic(message)
        module = types.ModuleType("anthropic")
        module.Anthropic = client.Anthropic
        monkeypatch.setitem(sys.modules, "anthropic", module)
        return client

    return install


@pytest.mark.parametrize(
    "model,expected",
    [
        ("claude-sonnet-5", True),
        ("claude-opus-5", True),
        ("claude-opus-4-8", True),
        ("claude-fable-5", False),
        ("claude-mythos-5", False),
    ],
)
def testSupportsDisabledThinking(model, expected):
    assert _supports_disabled_thinking(model) is expected


def testDisablesThinkingForSonnet(fake_anthropic):
    client = fake_anthropic(_FakeMessage('{"clips": []}'))
    AnthropicClient("claude-sonnet-5").complete("prompt", purpose="classify")
    assert client.messages.last_kwargs["thinking"] == {"type": "disabled"}


def testOmitsThinkingForFable(fake_anthropic):
    """Fable/Mythos 5 reject thinking={"type": "disabled"} with a 400."""
    client = fake_anthropic(_FakeMessage('{"clips": []}'))
    AnthropicClient("claude-fable-5").complete("prompt", purpose="classify")
    assert "thinking" not in client.messages.last_kwargs


def testRaisesOnMaxTokens(fake_anthropic):
    fake_anthropic(_FakeMessage("", stop_reason="max_tokens", output_tokens=4096))
    with pytest.raises(RuntimeError, match="max_tokens"):
        AnthropicClient("claude-sonnet-5").complete("prompt", purpose="classify")


def testRaisesOnEmptyText(fake_anthropic):
    fake_anthropic(_FakeMessage("", stop_reason="end_turn"))
    with pytest.raises(RuntimeError, match="empty response"):
        AnthropicClient("claude-sonnet-5").complete("prompt", purpose="classify")


# --- provider failure classification ---------------------------------------


class _SDKError(Exception):
    def __init__(self, message, *, body=None):
        super().__init__(message)
        self.message = message
        self.body = body


class _SDKStatusError(_SDKError):
    def __init__(self, message, *, status_code, body=None, headers=None):
        super().__init__(message, body=body)
        self.status_code = status_code
        self.response = types.SimpleNamespace(headers=headers or {})
        self.request_id = (headers or {}).get("request-id")


class _SDKConnectionError(_SDKError):
    def __init__(self, message="Connection error."):
        super().__init__(message)


class _SDKTimeoutError(_SDKConnectionError):
    def __init__(self):
        super().__init__("Request timed out or interrupted.")


class _SDKResponseValidationError(_SDKError):
    def __init__(self):
        super().__init__("Data returned by API invalid for expected schema.")


class _RaisingMessages:
    def __init__(self, error):
        self.error = error

    def create(self, **kwargs):
        raise self.error


@pytest.fixture
def failing_anthropic(monkeypatch):
    """Mirrors the SDK exception hierarchy (CI does not install anthropic)."""

    def install(error):
        module = types.ModuleType("anthropic")
        module.APIStatusError = _SDKStatusError
        module.APIConnectionError = _SDKConnectionError
        module.APITimeoutError = _SDKTimeoutError
        module.APIResponseValidationError = _SDKResponseValidationError
        module.Anthropic = lambda: types.SimpleNamespace(messages=_RaisingMessages(error))
        monkeypatch.setitem(sys.modules, "anthropic", module)

    return install


def _body(message, kind="invalid_request_error"):
    return {"type": "error", "error": {"type": kind, "message": message}}


def _anthropic_failure(error):
    from cut_suggester.llm import LLMError

    with pytest.raises(LLMError) as caught:
        AnthropicClient("claude-sonnet-5").complete("prompt", purpose="classify")
    assert caught.value.__cause__ is error
    return caught.value


def _record(exc):
    from cut_suggester.llm import failure_record

    return failure_record(exc)


def testLowCreditBalanceIsACreditsFailureWithProviderFacts(failing_anthropic):
    message = "Your credit balance is too low to access the Anthropic API."
    error = _SDKStatusError(
        "Error code: 400", status_code=400, body=_body(message), headers={"request-id": "req_01ABC"})
    failing_anthropic(error)
    assert _record(_anthropic_failure(error)) == {
        "category": "credits", "message": message, "status_code": 400,
        "request_id": "req_01ABC", "retry_after": None, "retryable": False,
        "error_type": "_SDKStatusError",
    }


@pytest.mark.parametrize(
    "status,body,category,retryable",
    [
        (401, _body("invalid x-api-key", "authentication_error"), "auth", False),
        (403, _body("not allowed", "permission_error"), "bad_request", False),
        (400, _body("max_tokens: too large"), "bad_request", False),
        (400, _body("unbalanced quotation marks in messages"), "bad_request", False),
        (429, _body("rate limited", "rate_limit_error"), "rate_limit", True),
        (529, _body("Overloaded", "overloaded_error"), "overloaded", True),
        (500, _body("Overloaded", "overloaded_error"), "overloaded", True),
        (500, _body("Internal server error", "api_error"), "server", True),
        (503, None, "server", True),
    ],
)
def testStatusErrorsMapToCategories(failing_anthropic, status, body, category, retryable):
    error = _SDKStatusError(f"Error code: {status}", status_code=status, body=body)
    failing_anthropic(error)
    record = _record(_anthropic_failure(error))
    assert (record["category"], record["retryable"], record["status_code"]) == (
        category, retryable, status)


def testRateLimitKeepsRetryAfterSeconds(failing_anthropic):
    error = _SDKStatusError(
        "Error code: 429", status_code=429, body=_body("rate limited", "rate_limit_error"),
        headers={"retry-after": "30"})
    failing_anthropic(error)
    assert _record(_anthropic_failure(error))["retry_after"] == 30


def testUnparseableRetryAfterIsDropped(failing_anthropic):
    error = _SDKStatusError(
        "Error code: 429", status_code=429, body=None,
        headers={"retry-after": "Wed, 21 Oct 2026 07:28:00 GMT"})
    failing_anthropic(error)
    assert _record(_anthropic_failure(error))["retry_after"] is None


def testConnectionErrorNamesTheTLSRootCause(failing_anthropic):
    import ssl

    error = _SDKConnectionError()
    try:
        try:
            raise ssl.SSLCertVerificationError(
                1, "[SSL: CERTIFICATE_VERIFY_FAILED] certificate verify failed")
        except ssl.SSLError as tls:
            raise OSError("connect failed") from tls
    except OSError as transport:
        error.__cause__ = transport
    failing_anthropic(error)
    record = _record(_anthropic_failure(error))
    assert record["category"] == "network"
    assert record["retryable"] is True
    assert "CERTIFICATE_VERIFY_FAILED" in record["message"]
    assert record["message"].startswith("Connection error.")


def testTimeoutIsNotReportedAsNetwork(failing_anthropic):
    error = _SDKTimeoutError()
    failing_anthropic(error)
    assert _record(_anthropic_failure(error))["category"] == "timeout"


def testMalformedSDKResponseIsABadResponse(failing_anthropic):
    error = _SDKResponseValidationError()
    failing_anthropic(error)
    assert _record(_anthropic_failure(error))["category"] == "bad_response"


def testTruncatedResponseIsABadResponse(fake_anthropic):
    from cut_suggester.llm import LLMError

    fake_anthropic(_FakeMessage("", stop_reason="max_tokens"))
    with pytest.raises(LLMError) as caught:
        AnthropicClient("claude-sonnet-5").complete("prompt", purpose="classify")
    assert (caught.value.category, caught.value.retryable) == ("bad_response", True)


def testParserErrorsAreBadResponses():
    from cut_suggester.extraction import ExtractionError

    record = _record(ExtractionError("extraction response is not valid JSON"))
    assert record == {
        "category": "bad_response", "message": "extraction response is not valid JSON",
        "status_code": None, "request_id": None, "retry_after": None, "retryable": True,
        "error_type": "ExtractionError",
    }


def testUnexpectedErrorsAreUnknownAndRetryable():
    record = _record(RuntimeError("temporary provider failure"))
    assert (record["category"], record["message"], record["retryable"]) == (
        "unknown", "temporary provider failure", True)


def testRealSDKExceptionsClassify(monkeypatch):
    """Guards the duck-typed mirror above against the pinned SDK (0.121.0)."""
    anthropic = pytest.importorskip("anthropic")
    import httpx

    request = httpx.Request("POST", "https://api.anthropic.com/v1/messages")
    cases = [
        (anthropic.BadRequestError(
            "Error code: 400", body=_body("Your credit balance is too low to access the Anthropic API."),
            response=httpx.Response(400, headers={"request-id": "req_1"}, request=request)),
         ("credits", 400, "req_1")),
        (anthropic.RateLimitError(
            "Error code: 429", body=_body("slow down", "rate_limit_error"),
            response=httpx.Response(429, headers={"retry-after": "12"}, request=request)),
         ("rate_limit", 429, None)),
        (anthropic.OverloadedError(
            "Error code: 529", body=_body("Overloaded", "overloaded_error"),
            response=httpx.Response(529, request=request)),
         ("overloaded", 529, None)),
        (anthropic.APITimeoutError(request=request), ("timeout", None, None)),
        (anthropic.APIResponseValidationError(
            response=httpx.Response(200, request=request), body=None),
         ("bad_response", None, None)),
        (anthropic.APIConnectionError(request=request), ("network", None, None)),
    ]
    for error, expected in cases:
        fake = types.SimpleNamespace(messages=_RaisingMessages(error))
        monkeypatch.setattr(anthropic, "Anthropic", lambda fake=fake: fake)
        record = _record(_anthropic_failure(error))
        assert (record["category"], record["status_code"], record["request_id"]) == expected


# --- OpenAI (raw urllib) -----------------------------------------------------


def _openai_failure(monkeypatch, error):
    import urllib.request

    from cut_suggester.llm import LLMError, OpenAIClient

    monkeypatch.setenv("OPENAI_KEY", "sk-test")

    def fail(*args, **kwargs):
        raise error

    monkeypatch.setattr(urllib.request, "urlopen", fail)
    with pytest.raises(LLMError) as caught:
        OpenAIClient("gpt-4o").complete("prompt", purpose="classify")
    return _record(caught.value)


def _http_error(status, body, headers=None):
    import io
    import json
    import urllib.error
    from email.message import Message

    message = Message()
    for name, value in (headers or {}).items():
        message[name] = value
    return urllib.error.HTTPError(
        "https://api.openai.com/v1/chat/completions", status, "error", message,
        io.BytesIO(json.dumps(body).encode()))


def testOpenAIQuotaErrorIsCredits(monkeypatch):
    error = _http_error(
        429, {"error": {"message": "You exceeded your current quota.", "type": "insufficient_quota",
                        "code": "insufficient_quota"}},
        {"x-request-id": "req_oa", "retry-after": "20"})
    record = _openai_failure(monkeypatch, error)
    assert (record["category"], record["status_code"], record["request_id"], record["message"]) == (
        "credits", 429, "req_oa", "You exceeded your current quota.")


def testOpenAIInvalidKeyIsAuth(monkeypatch):
    error = _http_error(401, {"error": {"message": "Incorrect API key provided."}})
    assert _openai_failure(monkeypatch, error)["category"] == "auth"


def testOpenAIRateLimitKeepsRetryAfter(monkeypatch):
    error = _http_error(429, {"error": {"message": "Rate limit reached."}}, {"retry-after": "7"})
    record = _openai_failure(monkeypatch, error)
    assert (record["category"], record["retry_after"]) == ("rate_limit", 7)


def testOpenAITLSFailureIsNetworkWithCause(monkeypatch):
    import ssl
    import urllib.error

    error = urllib.error.URLError(ssl.SSLCertVerificationError(
        1, "[SSL: CERTIFICATE_VERIFY_FAILED] certificate verify failed"))
    record = _openai_failure(monkeypatch, error)
    assert record["category"] == "network"
    assert "CERTIFICATE_VERIFY_FAILED" in record["message"]


@pytest.mark.parametrize("make", [
    lambda: TimeoutError("timed out"),
    lambda: __import__("urllib.error").error.URLError(TimeoutError("timed out")),
])
def testOpenAITimeoutIsTimeout(monkeypatch, make):
    assert _openai_failure(monkeypatch, make())["category"] == "timeout"


@pytest.mark.parametrize("body", [
    {"choices": []}, {"choices": [{"finish_reason": "stop"}]},
    {"choices": [{"message": {"content": None}}]},
])
def testOpenAIMalformedResponseIsABadResponse(monkeypatch, body):
    import io
    import json
    import urllib.request

    from cut_suggester.llm import LLMError, OpenAIClient

    monkeypatch.setenv("OPENAI_KEY", "sk-test")
    monkeypatch.setattr(urllib.request, "urlopen",
                        lambda *a, **k: io.BytesIO(json.dumps(body).encode()))
    with pytest.raises(LLMError) as caught:
        OpenAIClient("gpt-4o").complete("prompt", purpose="classify")
    assert caught.value.category == "bad_response"
