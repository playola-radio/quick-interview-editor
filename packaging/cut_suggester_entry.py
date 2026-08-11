"""Frozen cut-suggester entry point (PyInstaller one-folder).

Thin wrapper around ``cut_suggester.cli.main()`` — the same ``suggest`` driver the
app shells to in dev, and the same code the regression eval runs. Unlike the
whisperx ``engine_entry.py`` there is no NLTK/model wiring to do: the cutter's only
non-stdlib dependency is the ``anthropic`` SDK (lazy-imported on the Anthropic
provider path), and the OpenAI path is stdlib ``urllib``. Model weights are never
involved — the LLM runs over the network, keyed from the child's environment.
"""

from __future__ import annotations


def main() -> int:
    from cut_suggester.cli import main as cli_main

    return cli_main()


if __name__ == "__main__":
    raise SystemExit(main())
