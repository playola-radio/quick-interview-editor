# -*- mode: python ; coding: utf-8 -*-
"""PyInstaller one-folder freeze of the logic-markers engine.

Produces ``packaging/dist/logic-markers-engine/`` — a ``logic-markers-engine``
executable plus an ``_internal/`` tree of torch/ctranslate2/torchaudio native
libs and package data. The app bundles this whole folder under
``QuickInterviewEditor.app/Contents/Resources/engine/`` and spawns the
executable directly (no system Python required).

Run via ``packaging/package-engine.sh`` (which stages the bundled NLTK data
first). Apple Silicon only for the spike (``target_arch='arm64'``).
"""

import os

from PyInstaller.utils.hooks import (
    collect_all,
    collect_data_files,
    collect_submodules,
    copy_metadata,
)

# PyInstaller resolves relative paths in a .spec against the spec's own
# directory, not the invocation CWD. Anchor everything on absolute paths derived
# from SPECPATH (the packaging/ dir) so the freeze works from any CWD.
_HERE = SPECPATH  # noqa: F821 — injected by PyInstaller at spec exec time
_REPO = os.path.dirname(_HERE)

datas = []
binaries = []
hiddenimports = []

# Packages PyInstaller under-collects (native libs, lazy submodules, metadata).
# Only ones actually installed in the build venv; missing ones are skipped so
# the spec stays portable across engine dependency changes.
_COLLECT = [
    "torch",
    "torchaudio",
    "ctranslate2",
    "faster_whisper",
    "whisperx",
    "transformers",
    "tokenizers",
    "huggingface_hub",
    "pyannote",
    "pytorch_lightning",
    "lightning_fabric",
    "asteroid_filterbanks",
    "pandas",
    "nltk",
]
for pkg in _COLLECT:
    try:
        pkg_datas, pkg_binaries, pkg_hidden = collect_all(pkg)
    except (ModuleNotFoundError, ImportError) as exc:
        # Only "not installed" is tolerated; any other failure (e.g. a hook bug on
        # a core dep) must fail the build loudly rather than silently ship an
        # incomplete bundle that breaks at offline verification / on a clean Mac.
        print(f"[engine.spec] collect_all({pkg}) skipped: {exc}")
        continue
    datas += pkg_datas
    binaries += pkg_binaries
    hiddenimports += pkg_hidden

# WhisperX ships data assets (the pyannote VAD weights + mel filters) that are
# not Python modules — collect_all misses these, so grab them explicitly. These
# ship *inside* the notarized bundle (static data, signed + notarized).
datas += collect_data_files("whisperx", includes=["assets/*"])

# Package METADATA (.dist-info). transformers version-checks several packages at
# import time via importlib.metadata.version(...), which raises
# PackageNotFoundError if the metadata isn't bundled even when the package IS.
# The blocker here is `transformers/audio_utils.py` reading torchcodec's version;
# bundle it plus the other commonly version-checked deps defensively.
for meta_pkg in [
    "torchcodec",
    "torch",
    "torchaudio",
    "transformers",
    "tokenizers",
    "huggingface-hub",
    "safetensors",
    "numpy",
    "tqdm",
    "regex",
    "requests",
    "filelock",
    "packaging",
    "pyyaml",
    "faster-whisper",
    "ctranslate2",
]:
    try:
        datas += copy_metadata(meta_pkg)
    except (ModuleNotFoundError, ImportError) as exc:  # tolerate only "not installed"
        print(f"[engine.spec] copy_metadata({meta_pkg}) skipped: {exc}")

# whisperx.vads.* and the transformers wav2vec2 model are imported dynamically.
hiddenimports += collect_submodules("whisperx")
hiddenimports += [
    "transformers.models.wav2vec2",
    "transformers.models.wav2vec2.modeling_wav2vec2",
]

# Bundled NLTK punkt_tab (staged by package-engine.sh). Shipped as static data
# so WhisperX alignment never calls nltk.download() at runtime.
_nltk_dir = os.path.join(_HERE, "build", "nltk_data")
if os.path.isdir(_nltk_dir):
    datas.append((_nltk_dir, "nltk_data"))
else:
    print(f"[engine.spec] WARNING: bundled nltk_data missing at {_nltk_dir}")


a = Analysis(
    [os.path.join(_HERE, "engine_entry.py")],
    pathex=[_REPO],
    binaries=binaries,
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    noarchive=False,
)

pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name="logic-markers-engine",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=True,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch="arm64",
    codesign_identity=None,  # signed later, inside-out, by packaging/sign-app.sh
    entitlements_file=None,
)

coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=False,
    upx_exclude=[],
    name="logic-markers-engine",
)
