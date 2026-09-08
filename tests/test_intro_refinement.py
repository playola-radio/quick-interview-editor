"""Structural regressions; scripted responses are not editorial-quality evidence."""

import copy
import json
from dataclasses import replace

import pytest

from cut_suggester.llm import LLMResponse
from cut_suggester.models import Sentence


def sentences(count=10):
    return [Sentence(i, i, f"Here is Song {i}.", (i,), i * 2, (i + 1) * 2,
                     i * 2000, (i + 1) * 2000) for i in range(count)]


def proposal(start=0, end=3):
    return dict(type="intro", start=start, end=end, label="Coarse handoffs", song="Parent song")


def take(start=0, end=1):
    return dict(start=start, end=end, label="Complete song handoff", song=f"Song {start}")


class Provider:
    def __init__(self, responses):
        self.responses = iter(responses)
        self.calls = []

    def complete(self, prompt, *, purpose=""):
        self.calls.append((purpose, prompt))
        return LLMResponse(json.dumps(next(self.responses)))


def test_refines_split_drop_and_per_take_song_without_changing_spotlight():
    from cut_suggester.intro_refinement import refine_intro_clips
    spotlight = dict(type="spotlight", start=4, end=8, label="Untouched story", song=None)
    raw = [proposal(), spotlight, proposal(9, 9)]
    before = copy.deepcopy(raw)
    llm = Provider([{"results": [
        {"proposal_id": "p0", "takes": [take(), take(2, 3)]},
        {"proposal_id": "p2", "takes": []},
    ]}])
    result = refine_intro_clips(sentences(), raw, llm, guidance="ONE complete handoff.")
    assert result == [dict(type="intro", **take()), dict(type="intro", **take(2, 3)), spotlight]
    assert result[-1] is spotlight
    assert raw == before
    assert "[2] Here is Song 2." in llm.calls[0][1]
    assert "ONE complete handoff." in llm.calls[0][1]


@pytest.mark.parametrize("change", [
    lambda r: r.update(extra=True),
    lambda r: r.update(results=[]),
    lambda r: r["results"].append(copy.deepcopy(r["results"][0])),
    lambda r: r["results"][0].update(proposal_id="foreign"),
    lambda r: r["results"][0].update(takes=None),
    lambda r: r["results"][0]["takes"].append(take(1, 2)),
    lambda r: r["results"][0]["takes"][0].update(start=True),
    lambda r: r["results"][0]["takes"][0].update(end=1.0),
    lambda r: r["results"][0]["takes"][0].update(start=-1),
    lambda r: r["results"][0]["takes"][0].update(end=4),
    lambda r: r["results"][0]["takes"][0].update(start=2),
    lambda r: r["results"][0]["takes"][0].update(label=" "),
    lambda r: r["results"][0]["takes"][0].update(song=1),
    lambda r: r["results"][0]["takes"][0].update(song="Invented recording"),
    lambda r: r["results"][0]["takes"][0].pop("song"),
])
def test_rejects_malformed_or_unsupported_refinement(change):
    from cut_suggester.intro_refinement import IntroRefinementError, refine_intro_clips
    response = {"results": [{"proposal_id": "p0", "takes": [take()]}]}
    change(response)
    with pytest.raises(IntroRefinementError):
        refine_intro_clips(sentences(), [proposal()], Provider([response]), guidance="Handoff.")


def test_duplicate_json_keys_are_rejected():
    from cut_suggester.intro_refinement import IntroRefinementError, refine_intro_clips
    class Duplicate:
        def complete(self, *args, **kwargs):
            return LLMResponse('{"results":[],"results":[{"proposal_id":"p0","takes":[]}]}')
    with pytest.raises(IntroRefinementError, match="duplicate"):
        refine_intro_clips(sentences(), [proposal()], Duplicate(), guidance="Handoff.")


def test_batches_are_bounded_and_keep_global_proposal_references():
    from cut_suggester.intro_refinement import refine_intro_clips
    llm = Provider([{"results": [{"proposal_id": f"p{i}", "takes": [take(i, i)]}]}
                    for i in range(3)])
    result = refine_intro_clips(sentences(), [proposal(i, i) for i in range(3)], llm,
                               guidance="Handoff.", max_proposals=1, max_input_characters=3000)
    assert len(result) == len(llm.calls) == 3
    assert all(len(prompt) <= 3000 for _, prompt in llm.calls)
    assert "Proposal p2 (2 through 2)" in llm.calls[-1][1]
    assert len({purpose for purpose, _ in llm.calls}) == 3


def test_oversized_evidence_fails_before_any_paid_request():
    from cut_suggester.intro_refinement import IntroRefinementError, refine_intro_clips
    llm = Provider([])
    with pytest.raises(IntroRefinementError, match="input limit"):
        refine_intro_clips(sentences(), [proposal()], llm, guidance="x" * 5000,
                           max_input_characters=3000)
    assert llm.calls == []


def test_refinement_instructions_preserve_relevant_setup_before_complete_handoff():
    from cut_suggester.intro_refinement import refine_intro_clips
    llm = Provider([{'results': [{'proposal_id': 'p0', 'takes': [take(0, 3)]}]}])
    out = refine_intro_clips(sentences(), [proposal()], llm, guidance='A complete introduction.')
    assert (out[0]['start'], out[0]['end']) == (0, 3)
    assert 'Retain the full contiguous relevant setup' in llm.calls[0][1]
    assert 'performer identification and background about the introduced recording' in llm.calls[0][1]


def test_character_bound_splits_batches_and_oversized_later_proposal_spends_nothing():
    from cut_suggester.intro_refinement import IntroRefinementError, refine_intro_clips
    source = [replace(s, text='Handoff context. ' * 130) for s in sentences(2)]
    llm = Provider([{'results': [{'proposal_id': f'p{i}', 'takes': []}]} for i in range(2)])
    assert refine_intro_clips(source, [proposal(0, 0), proposal(1, 1)], llm,
                              guidance='Complete handoff.', max_input_characters=4500) == []
    assert len(llm.calls) == 2
    assert all(len(prompt) <= 4500 for _, prompt in llm.calls)
    source[1] = replace(source[1], text='x' * 5000)
    llm = Provider([])
    with pytest.raises(IntroRefinementError, match='p1.*input limit'):
        refine_intro_clips(source, [proposal(0, 0), proposal(1, 1)], llm,
                           guidance='Complete handoff.', max_input_characters=4500)
    assert llm.calls == []


@pytest.mark.parametrize('title', ['Me', 'The', 'Of Me'])
def test_stopword_only_song_title_supported_by_exact_take_evidence_is_valid(title):
    from cut_suggester.intro_refinement import refine_intro_clips
    from cut_suggester.postprocess import verify_song
    source = [replace(sentences(1)[0], text=f'Here is "{title}".')]
    final_take = dict(start=0, end=0, label='A complete song handoff', song=title)
    llm = Provider([{'results': [{'proposal_id': 'p0', 'takes': [final_take]}]}])
    assert refine_intro_clips(source, [proposal(0, 0)], llm, guidance='Complete handoff.') == [
        dict(type='intro', **final_take)]
    assert not verify_song(title, source[0].text)  # Legacy verifier remains unchanged.


@pytest.mark.parametrize('title,text', [('Me', 'Here is Theme.'), ('Of Me', 'Of course, listen to me.')])
def test_stopword_title_requires_whole_words_in_the_exact_phrase(title, text):
    from cut_suggester.intro_refinement import IntroRefinementError, refine_intro_clips
    source = [replace(sentences(1)[0], text=text)]
    llm = Provider([{'results': [{'proposal_id': 'p0', 'takes': [
        dict(start=0, end=0, label='Song handoff', song=title)]}]}])
    with pytest.raises(IntroRefinementError, match='supported by that take'):
        refine_intro_clips(source, [proposal(0, 0)], llm, guidance='Complete handoff.')
