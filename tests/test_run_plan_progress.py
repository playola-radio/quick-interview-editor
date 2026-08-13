import json

import logic_markers.cli as cli
import logic_markers.whisperx_backend as backend
from logic_markers.words import Transcript, Word as RichWord


def test_load_or_transcribe_forwards_stage_progress(monkeypatch, tmp_path, capsys):
    def fake_transcribe_transcript(_source, progress_callback=None) -> Transcript:
        assert progress_callback is not None
        progress_callback("transcribe", 0.25)
        progress_callback("align", 0.75)
        return Transcript(words=(RichWord(id=1, text="hi", start=0.0, end=1.0),),
                          segments=())

    monkeypatch.setattr(backend, "transcribe_transcript", fake_transcribe_transcript)

    transcribe = cli._PhaseEmitter(1, 3, "transcribing", "Transcribing", "T…")
    align = cli._PhaseEmitter(2, 3, "aligning", "Aligning words", "A…")
    router = cli._StageRouter(transcribe, align)
    cli._load_or_transcribe_transcript_in(
        tmp_path / "a.wav", tmp_path, refresh=False, on_progress=router
    )
    lines = [line for line in capsys.readouterr().err.splitlines() if line.startswith("QIE_EVENT ")]
    events = [json.loads(line[len("QIE_EVENT "):]) for line in lines]
    # transcribe 0.25 (phase 1); the first align caps phase 1 at 1.0, then align 0.75
    # emits as phase 2. (No router.finish() here, so phase 2 isn't capped.)
    assert [(e["phase_index"], e["fraction"]) for e in events] == [
        (1, 0.25), (1, 1.0), (2, 0.75),
    ]


def test_load_or_transcribe_fires_on_start_only_on_cache_miss(monkeypatch, tmp_path):
    def fake_transcribe_transcript(_source, progress_callback=None) -> Transcript:
        return Transcript(words=(RichWord(id=1, text="hi", start=0.0, end=1.0),),
                          segments=())

    monkeypatch.setattr(backend, "transcribe_transcript", fake_transcribe_transcript)

    started = []
    # First call: no cache yet -> transcription runs -> on_start fires and the cache
    # is written.
    cli._load_or_transcribe_transcript_in(
        tmp_path / "a.wav", tmp_path, refresh=False, on_start=lambda: started.append("miss")
    )
    assert started == ["miss"]
    # Second call: cache hit -> transcription is skipped -> on_start must NOT fire, so a
    # cached run never announces (and never emits) the transcribe phase.
    cli._load_or_transcribe_transcript_in(
        tmp_path / "a.wav", tmp_path, refresh=False, on_start=lambda: started.append("hit")
    )
    assert started == ["miss"]
