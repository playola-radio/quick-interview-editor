"""Frozen-engine entry point (PyInstaller one-folder).

Thin wrapper around ``logic_markers.cli.main()``. Its one extra job is to wire
the *bundled* NLTK ``punkt_tab`` data — shipped as static data inside the frozen
bundle — so WhisperX alignment never triggers a runtime ``nltk.download()``
(which would try to fetch code/data over the network post-notarization).

Model *weights* are deliberately NOT bundled here: they are downloaded by the
app into Application Support and passed to the engine via ``QIE_*`` env vars.
"""

from __future__ import annotations

import os
import sys


def _wire_bundled_nltk_data() -> None:
    """Point ``NLTK_DATA`` at the punkt_tab shipped inside the frozen bundle.

    PyInstaller exposes the unpacked bundle root via ``sys._MEIPASS``. We
    prepend it so the shipped tokenizer wins and NLTK never reaches the network.
    """
    base = getattr(sys, "_MEIPASS", None)
    if not base:
        return
    nltk_dir = os.path.join(base, "nltk_data")
    if os.path.isdir(nltk_dir):
        existing = os.environ.get("NLTK_DATA", "")
        os.environ["NLTK_DATA"] = (
            nltk_dir + os.pathsep + existing if existing else nltk_dir
        )


def main() -> int:
    _wire_bundled_nltk_data()
    from logic_markers.cli import main as cli_main

    return cli_main()


if __name__ == "__main__":
    raise SystemExit(main())
