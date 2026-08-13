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
