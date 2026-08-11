import json

import logic_markers.cli as cli
import logic_markers.whisperx_backend as backend
from logic_markers.words import Transcript, Word as RichWord


def test_load_or_transcribe_forwards_on_progress(monkeypatch, tmp_path, capsys):
    seen = []

    def fake_transcribe_transcript(source, progress_callback=None):
        assert progress_callback is not None
        progress_callback(0.25)
        progress_callback(0.75)
        return Transcript(words=(RichWord(id=1, text="hi", start=0.0, end=1.0),),
                          segments=())

    monkeypatch.setattr(backend, "transcribe_transcript", fake_transcribe_transcript)

    emitter = cli._ProgressEmitter()
    cli._load_or_transcribe_transcript_in(
        tmp_path / "a.wav", tmp_path, refresh=False, on_progress=emitter
    )
    lines = [line for line in capsys.readouterr().err.splitlines() if line.startswith("QIE_EVENT ")]
    fractions = [json.loads(line[len("QIE_EVENT "):]).get("fraction") for line in lines]
    assert fractions == [0.25, 0.75]
