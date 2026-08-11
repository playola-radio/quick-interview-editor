# -*- mode: python ; coding: utf-8 -*-
"""PyInstaller one-folder freeze of the cut-suggester helper.

Produces ``packaging/dist/cut-suggester-engine/`` — a ``cut-suggester-engine``
executable plus a ``_cut_suggester_internal/`` tree of the ``anthropic`` SDK stack
(pydantic/httpx/certifi/...) and package data.

The contents dir is deliberately **not** the default ``_internal``: ``build-app.sh``
dittos this bundle into the SAME ``Contents/Resources/engine/`` folder as the frozen
``logic-markers-engine`` (whose libs live in ``_internal/``). A distinct
``contents_directory`` keeps the two bundles' support trees from colliding, while the
only shared-namespace top-level artifact — the executable itself — lands at exactly
``Resources/engine/cut-suggester-engine`` (the path the Swift ``CutSuggesterResolver``
seam already expects). One-folder (not one-file) so ``sign-app.sh`` can sign every
nested Mach-O inside-out under the hardened runtime.

Run via ``packaging/package-cut-suggester.sh``. Apple Silicon only (``arm64``).

Unlike ``engine.spec`` this is small: the cutter's whole runtime is CPython stdlib
plus the ``anthropic`` SDK (lazy-imported on the Anthropic provider path). The OpenAI
path uses stdlib ``urllib`` — no SDK. No torch/whisperx/numpy.
"""

import os

from PyInstaller.utils.hooks import collect_all, copy_metadata

# PyInstaller resolves relative paths in a .spec against the spec's own directory,
# not the invocation CWD. Anchor on absolute paths derived from SPECPATH (packaging/)
# so the freeze works from any CWD, exactly like engine.spec.
_HERE = SPECPATH  # noqa: F821 — injected by PyInstaller at spec exec time
_REPO = os.path.dirname(_HERE)

datas = []
binaries = []
hiddenimports = []

# The anthropic SDK and its transitive stack. `anthropic` is imported lazily inside
# the Anthropic provider path, and pydantic/httpx pull native extensions
# (pydantic_core, jiter) + lazy submodules that PyInstaller under-collects. Only
# packages actually installed in the build venv are collected; a missing one is
# skipped so the spec stays portable if the provider stack changes (mirrors
# engine.spec's tolerate-"not installed"-only policy).
_COLLECT = [
    "anthropic",
    "pydantic",
    "pydantic_core",
    "httpx",
    "httpcore",
    "anyio",
    "sniffio",
    "distro",
    "certifi",
    "jiter",
    "h11",
    "idna",
    "annotated_types",
    "typing_extensions",
]
for pkg in _COLLECT:
    try:
        pkg_datas, pkg_binaries, pkg_hidden = collect_all(pkg)
    except (ModuleNotFoundError, ImportError) as exc:
        # Only "not installed" is tolerated; any other failure (a hook bug on a core
        # dep) must fail the build loudly rather than silently ship a bundle that
        # breaks at runtime on a clean Mac.
        print(f"[cut-suggester.spec] collect_all({pkg}) skipped: {exc}")
        continue
    datas += pkg_datas
    binaries += pkg_binaries
    hiddenimports += pkg_hidden

# Package METADATA (.dist-info). The anthropic SDK (and pydantic/httpx) read their own
# versions at import time via importlib.metadata.version(...), which raises
# PackageNotFoundError if the metadata isn't bundled even when the package IS. Bundle
# the stack's metadata defensively so a lazy `import anthropic` can't die on a version
# lookup post-freeze.
for meta_pkg in [
    "anthropic",
    "pydantic",
    "pydantic-core",
    "httpx",
    "httpcore",
    "anyio",
    "sniffio",
    "distro",
    "certifi",
    "jiter",
    "typing-extensions",
    "annotated-types",
    "idna",
    "h11",
]:
    try:
        datas += copy_metadata(meta_pkg)
    except (ModuleNotFoundError, ImportError) as exc:  # tolerate only "not installed"
        print(f"[cut-suggester.spec] copy_metadata({meta_pkg}) skipped: {exc}")


a = Analysis(
    [os.path.join(_HERE, "cut_suggester_entry.py")],
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
    name="cut-suggester-engine",
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
    # Distinct from logic-markers-engine's default `_internal` so both bundles can
    # share one Resources/engine/ dir without their support trees colliding. This is
    # an EXE kwarg that COLLECT reads back off the EXE it's handed (PyInstaller 6
    # ignores a contents_directory passed to COLLECT directly), so it must live here.
    contents_directory="_cut_suggester_internal",
)

coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=False,
    upx_exclude=[],
    name="cut-suggester-engine",
)
