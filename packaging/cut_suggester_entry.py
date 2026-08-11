"""Frozen cut-suggester entry point (PyInstaller one-folder).

Thin wrapper around ``cut_suggester.cli.main()`` — the same ``suggest`` driver the
app shells to in dev, and the same code the regression eval runs. Unlike the
whisperx ``engine_entry.py`` there is no NLTK/model wiring to do: the cutter's only
non-stdlib dependency is the ``anthropic`` SDK (lazy-imported on the Anthropic
provider path), and the OpenAI path is stdlib ``urllib``. Model weights are never
involved — the LLM runs over the network, keyed from the child's environment.
"""

from __future__ import annotations

import os
import sys


def _wire_bundled_ca_bundle() -> None:
    """Point the SSL trust store at the certifi CA bundle shipped inside the frozen
    bundle, so live HTTPS works on a clean Mac.

    The whisperx ``engine_entry.py`` wires ``NLTK_DATA`` for the same reason; the
    cutter's analog is TLS trust. The Anthropic path (httpx) already uses certifi,
    but the OpenAI path is stdlib ``urllib.request``, whose default OpenSSL CA path
    is baked at *build* time and generally does not exist on a user's Mac — the
    frozen bundle would otherwise raise ``CERTIFICATE_VERIFY_FAILED``. Setting
    ``SSL_CERT_FILE`` makes ``ssl.create_default_context()`` (and therefore urllib)
    load the bundled bundle. ``setdefault`` so an explicit user override still wins.
    """
    if not getattr(sys, "frozen", False):
        return
    try:
        import certifi
    except ModuleNotFoundError:
        return
    ca = certifi.where()
    if not os.path.isfile(ca):
        return
    os.environ.setdefault("SSL_CERT_FILE", ca)
    os.environ.setdefault("REQUESTS_CA_BUNDLE", ca)


def main() -> int:
    _wire_bundled_ca_bundle()
    from cut_suggester.cli import main as cli_main

    return cli_main()


if __name__ == "__main__":
    raise SystemExit(main())
