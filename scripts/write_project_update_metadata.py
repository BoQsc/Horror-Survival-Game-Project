import argparse
import json
import subprocess
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = ROOT / "project_update_state.json"


def run_git(args: list[str], default: str = "") -> str:
    result = subprocess.run(
        ["git", "-C", str(ROOT), *args],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if result.returncode != 0:
        return default
    return result.stdout.strip()


def normalize_repo(remote_url: str) -> str:
    remote_url = remote_url.strip()
    if remote_url.endswith(".git"):
        remote_url = remote_url[:-4]
    if remote_url.startswith("https://github.com/"):
        return remote_url.removeprefix("https://github.com/")
    if remote_url.startswith("git@github.com:"):
        return remote_url.removeprefix("git@github.com:")
    return remote_url


def main() -> int:
    parser = argparse.ArgumentParser(description="Write launch updater metadata for this checkout.")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()

    branch = run_git(["rev-parse", "--abbrev-ref", "HEAD"], "UNKNOWN")
    commit = run_git(["rev-parse", "HEAD"], "")
    upstream = run_git(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], "")
    remote_name = upstream.split("/", 1)[0] if "/" in upstream else "origin"
    remote_url = run_git(["remote", "get-url", remote_name], "")

    metadata = {
        "schema": 1,
        "repo": normalize_repo(remote_url) or "BoQsc/gpu-marching-cubes",
        "remote": remote_name,
        "branch": branch,
        "upstream": upstream,
        "commit": commit,
        "update_method": "git_pull_ff_only",
        "generated_at_unix": int(time.time()),
    }

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(metadata, indent="\t") + "\n", encoding="utf-8")
    print(args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
