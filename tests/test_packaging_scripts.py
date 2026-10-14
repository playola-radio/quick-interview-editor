import os
import subprocess
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parent.parent


@pytest.mark.parametrize("script", ["package-engine.sh", "package-cut-suggester.sh"])
def test_package_script_rejects_non_standalone_venv(tmp_path, script):
    python = tmp_path / ".venv" / "bin" / "python"
    python.parent.mkdir(parents=True)
    python.write_text(
        "#!/usr/bin/env bash\n"
        "if [[ \"$2\" == *'sys.base_prefix'* ]]; then\n"
        "  echo /not/python-build-standalone\n"
        "  exit 0\n"
        "fi\n"
        "exit 1\n"
    )
    python.chmod(0o755)

    result = subprocess.run(
        ["bash", ROOT / "packaging" / script],
        cwd=ROOT,
        env={**os.environ, "VENV": str(python.parent.parent)},
        capture_output=True,
        text=True,
    )

    assert result.returncode == 1
    assert "Create it with packaging/make-build-venv.sh." in result.stderr
