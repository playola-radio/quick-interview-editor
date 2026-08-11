import sys
import types

import numpy as np

import logic_markers.whisperx_backend as backend


def _install_fake_whisperx(monkeypatch, calls):
    fake = types.ModuleType("whisperx")

    class _Model:
        def transcribe(self, audio, batch_size=None, combined_progress=False,
                       progress_callback=None):
            calls.append(("transcribe", combined_progress))
            if progress_callback:
                progress_callback(25.0)
                progress_callback(50.0)
            return {"language": "en", "segments": [{"text": "hi", "start": 0.0, "end": 1.0}]}

    def load_model(arch, device, compute_type=None, local_files_only=False):
        return _Model()

    def load_align_model(language_code=None, device=None, model_dir=None,
                         model_cache_only=False):
        return object(), {}

    def align(segments, align_model, metadata, audio, device,
              return_char_alignments=False, combined_progress=False,
              progress_callback=None):
        calls.append(("align", combined_progress))
        if progress_callback:
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


def test_progress_callback_forwarded_to_both_stages(monkeypatch, tmp_path):
    calls = []
    _install_fake_whisperx(monkeypatch, calls)
    received = []
    backend.transcribe_transcript(tmp_path / "x.wav", progress_callback=lambda p: received.append(p))
    assert ("transcribe", True) in calls
    assert ("align", True) in calls
    assert received == [25.0, 50.0, 75.0, 100.0]


def test_no_callback_still_works(monkeypatch, tmp_path):
    calls = []
    _install_fake_whisperx(monkeypatch, calls)
    result = backend.transcribe_transcript(tmp_path / "x.wav")  # no callback
    assert [w.text for w in result.words] == ["hi"]
