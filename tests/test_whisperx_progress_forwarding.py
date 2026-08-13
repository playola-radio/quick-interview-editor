import sys
import types

import numpy as np

import logic_markers.whisperx_backend as backend


def _install_fake_whisperx(monkeypatch, calls):
    fake = types.ModuleType("whisperx")

    class _Model:
        def transcribe(self, audio, batch_size=None, progress_callback=None):
            calls.append("transcribe")
            if progress_callback:
                # WhisperX gives each stage its own unscaled 0..100 sweep.
                progress_callback(25.0)
                progress_callback(50.0)
            return {"language": "en", "segments": [{"text": "hi", "start": 0.0, "end": 1.0}]}

    def load_model(arch, device, compute_type=None, local_files_only=False):
        return _Model()

    def load_align_model(language_code=None, device=None, model_dir=None,
                         model_cache_only=False):
        return object(), {}

    def align(segments, align_model, metadata, audio, device,
              return_char_alignments=False, progress_callback=None):
        calls.append("align")
        if progress_callback:
            # Also unscaled 0..100 for its own stage.
            progress_callback(75.0)
            progress_callback(100.0)
        return {"segments": [
            {"text": "hi", "start": 0.0, "end": 1.0,
             "words": [{"word": "hi", "start": 0.0, "end": 1.0}]}
        ]}

    fake.load_model = load_model
    fake.load_align_model = load_align_model
    fake.align = align
    monkeypatch.setitem(sys.modules, "whisperx", fake)
    # _load_audio_16k_mono shells out to afconvert; stub it to a tiny array.
    monkeypatch.setattr(backend, "_load_audio_16k_mono", lambda source: np.zeros(16000, dtype=np.float32))


def test_progress_callback_reports_each_stage_unscaled(monkeypatch, tmp_path):
    """Each WhisperX stage reports its OWN unscaled 0..1 progress, tagged with the
    stage name — no folding into halves. whisperx's progress_callback is unscaled
    per-stage (verified against 3.8.6's asr.py/alignment.py — `combined_progress`
    only scales the internal `print`, never the callback). The CLI owns the phase
    model (which stage is phase 1 vs 2); the backend just tags each stage.
    """
    calls = []
    _install_fake_whisperx(monkeypatch, calls)
    received = []
    backend.transcribe_transcript(
        tmp_path / "x.wav", progress_callback=lambda stage, f: received.append((stage, f))
    )
    assert calls == ["transcribe", "align"]
    # transcribe 25/50 (0..100) -> 0.25/0.5; align 75/100 (0..100) -> 0.75/1.0
    assert received == [
        ("transcribe", 0.25), ("transcribe", 0.5), ("align", 0.75), ("align", 1.0),
    ]


def test_no_callback_still_works(monkeypatch, tmp_path):
    calls = []
    _install_fake_whisperx(monkeypatch, calls)
    result = backend.transcribe_transcript(tmp_path / "x.wav")  # no callback
    assert [w.text for w in result.words] == ["hi"]
