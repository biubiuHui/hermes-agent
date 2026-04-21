from pathlib import Path
import os
import subprocess


REPO_ROOT = Path(__file__).resolve().parents[2]
UPDATE_SCRIPT = REPO_ROOT / "scripts" / "update-my-fork.sh"


def test_update_my_fork_script_is_valid_shell():
    result = subprocess.run(["bash", "-n", str(UPDATE_SCRIPT)], capture_output=True, text=True)

    assert result.returncode == 0, result.stderr


def test_update_my_fork_script_help_documents_safe_update_flow():
    result = subprocess.run(
        ["bash", str(UPDATE_SCRIPT), "--help"],
        capture_output=True,
        text=True,
        env={**os.environ, "NO_COLOR": "1"},
    )

    assert result.returncode == 0, result.stderr
    assert "git@github.com:biubiuHui/hermes-agent.git" in result.stdout
    assert "git@github.com:NousResearch/hermes-agent.git" in result.stdout
    assert "--skip-tests" in result.stdout
    assert "--no-push" in result.stdout
    assert "--yes" in result.stdout
