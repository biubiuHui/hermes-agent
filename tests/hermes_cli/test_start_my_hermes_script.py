from pathlib import Path
import os
import subprocess


REPO_ROOT = Path(__file__).resolve().parents[2]
START_SCRIPT = REPO_ROOT / "scripts" / "start-my-hermes.sh"


def test_start_my_hermes_script_is_valid_shell():
    result = subprocess.run(["bash", "-n", str(START_SCRIPT)], capture_output=True, text=True)

    assert result.returncode == 0, result.stderr


def test_start_my_hermes_script_help_documents_modes():
    result = subprocess.run(
        ["bash", str(START_SCRIPT), "--help"],
        capture_output=True,
        text=True,
        env={**os.environ, "NO_COLOR": "1"},
    )

    assert result.returncode == 0, result.stderr
    assert str(REPO_ROOT) in result.stdout
    assert "--skip-deps" in result.stdout
    assert "--force-deps" in result.stdout
    assert "--foreground" in result.stdout
    assert "--dry-run" in result.stdout


def test_start_my_hermes_script_dry_run_uses_repo_python():
    result = subprocess.run(
        ["bash", str(START_SCRIPT), "--dry-run", "--skip-deps"],
        capture_output=True,
        text=True,
        env={**os.environ, "NO_COLOR": "1"},
    )

    assert result.returncode == 0, result.stderr
    assert str(REPO_ROOT / "venv" / "bin" / "python") in result.stdout
    assert "-m hermes_cli.main gateway" in result.stdout
    assert any(
        marker in result.stdout
        for marker in ("gateway restart", "gateway start", "gateway run --replace")
    )
