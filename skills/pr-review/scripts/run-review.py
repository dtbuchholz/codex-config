"""Run one native Codex review, preserving diagnostics and checking for scope drift."""

import argparse
import hashlib
import json
import os
import signal
import subprocess
import sys
import tempfile
from pathlib import Path


def git(project, *args):
    result = subprocess.run(
        ["git", "-C", str(project), *args], capture_output=True, check=True
    )
    return result.stdout


def fingerprint(project, excluded):
    """Fingerprint the checkout, including untracked contents, without changing its index."""
    digest = hashlib.sha256()
    head = git(project, "rev-parse", "--verify", "HEAD").strip()
    digest.update(head)
    pathspec = ["."]
    for path in excluded:
        if path.is_relative_to(project):
            pathspec.append(f":(exclude,literal){path.relative_to(project)}")
    digest.update(
        git(
            project,
            "diff",
            "HEAD",
            "--binary",
            "--no-ext-diff",
            "--no-textconv",
            "--",
            *pathspec,
        )
    )
    for raw in git(project, "ls-files", "--others", "--exclude-standard", "-z").split(
        b"\0"
    ):
        if not raw:
            continue
        path = project / os.fsdecode(raw)
        if any(path == item or path.is_relative_to(item) for item in excluded):
            continue
        digest.update(raw + b"\0")
        if path.is_symlink():
            digest.update(os.fsencode(os.readlink(path)))
        elif path.is_file():
            with path.open("rb") as file:
                for chunk in iter(lambda: file.read(1024 * 1024), b""):
                    digest.update(chunk)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(
        description=__doc__,
        epilog="For specialist reviews and legacy packet options, use run-pr-review.sh --deep --help.",
    )
    parser.add_argument("project_dir", nargs="?", default=".")
    scope = parser.add_mutually_exclusive_group()
    scope.add_argument(
        "--uncommitted",
        action="store_true",
        help="Default: staged, unstaged, and untracked changes",
    )
    scope.add_argument("--base", help="Review changes against a base branch")
    scope.add_argument("--commit", help="Review one commit")
    parser.add_argument("--output-file", type=Path)
    parser.add_argument("--raw-log", type=Path, help="Optional JSONL event destination")
    parser.add_argument(
        "--timeout",
        type=int,
        default=os.environ.get("PR_REVIEW_TIMEOUT_SECONDS", "600"),
    )
    parser.add_argument("--model", help="Override the review model")
    parser.add_argument(
        "--reasoning-effort", choices=["low", "medium", "high", "xhigh"], default="high"
    )
    args = parser.parse_args()
    if args.timeout < 1:
        parser.error("--timeout must be positive")
    if (
        args.raw_log
        and args.output_file
        and args.raw_log.resolve() == args.output_file.resolve()
    ):
        parser.error("--raw-log and --output-file must be different paths")
    project = args_project = Path(args.project_dir).expanduser().resolve()
    try:
        project = Path(
            os.fsdecode(git(project, "rev-parse", "--show-toplevel")).strip()
        ).resolve()
        git(project, "rev-parse", "--verify", "HEAD")
        if args.base or args.commit:
            git(
                project,
                "rev-parse",
                "--verify",
                "--end-of-options",
                f"{args.base or args.commit}^{{commit}}",
            )
    except subprocess.CalledProcessError as exc:
        parser.error(
            f"invalid repository or review revision: {exc.stderr.decode(errors='replace').strip()}"
        )

    if args.output_file:
        report = args.output_file.expanduser().resolve()
    else:
        fd, name = tempfile.mkstemp(prefix="pr-review-report.", suffix=".md")
        os.close(fd)
        report = Path(name)
    report.parent.mkdir(parents=True, exist_ok=True)
    artifacts = Path(
        tempfile.mkdtemp(prefix=f"{report.name}.artifacts.", dir=report.parent)
    )
    raw = (
        args.raw_log.expanduser().resolve()
        if args.raw_log
        else artifacts / "events.jsonl"
    )
    raw.parent.mkdir(parents=True, exist_ok=True)
    stderr = artifacts / "stderr.log"
    final = artifacts / "review.md"
    excluded = [report, artifacts, raw]
    before = fingerprint(project, excluded)
    if args.base:
        target = ["--base", args.base]
    elif args.commit:
        target = ["--commit", args.commit]
    else:
        target = ["--uncommitted"]
    command = [
        "codex",
        "exec",
        "--sandbox",
        "read-only",
        "-c",
        'approval_policy="never"',
        "--disable",
        "memories",
        "--ephemeral",
        "-c",
        f'model_reasoning_effort="{args.reasoning_effort}"',
        "--json",
        "-o",
        str(final),
        "-C",
        str(project),
    ]
    if args.model:
        command.extend(["--model", args.model])
    command.extend(["review", *target])
    metadata = {
        "command": command,
        "project": str(project),
        "requested_directory": str(args_project),
        "scope": target,
        "before": before,
        "status": "running",
    }
    metadata_path = artifacts / "run.json"
    metadata_path.write_text(json.dumps(metadata, indent=2) + "\n")
    report.write_text(f"REVIEW IN PROGRESS\n\nArtifacts: {artifacts}\n")
    print(
        f"pr-review: native review {target}; artifacts -> {artifacts}", file=sys.stderr
    )
    failure = None
    exit_code = None
    with raw.open("wb") as stdout_file, stderr.open("wb") as stderr_file:
        try:
            process = subprocess.Popen(
                command,
                stdin=subprocess.DEVNULL,
                stdout=stdout_file,
                stderr=stderr_file,
                start_new_session=True,
            )
            try:
                exit_code = process.wait(timeout=args.timeout)
            except (subprocess.TimeoutExpired, KeyboardInterrupt) as exc:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                failure = (
                    f"timed out after {args.timeout}s"
                    if isinstance(exc, subprocess.TimeoutExpired)
                    else "interrupted"
                )
        except OSError as exc:
            failure = str(exc)
    if failure is None and exit_code != 0:
        failure = f"Codex exited with status {exit_code}"
    if failure is None and (not final.is_file() or not final.read_text().strip()):
        failure = "Codex returned no final review"
    try:
        after = fingerprint(project, excluded)
        metadata["after"] = after
        if after != before:
            failure = f"{failure + '; ' if failure else ''}checkout changed during review; rerun against the current state"
    except (OSError, subprocess.CalledProcessError) as exc:
        failure = f"could not verify checkout state: {exc}"
    metadata.update(
        status="failed" if failure else "complete", exit_code=exit_code, failure=failure
    )
    metadata_path.write_text(json.dumps(metadata, indent=2) + "\n")
    if failure:
        report.write_text(
            f"FAILED REVIEW - PARTIAL OUTPUTS\n\n{failure}\n\nArtifacts: {artifacts}\n"
        )
        print(
            f"error: {failure}; stderr -> {stderr}; events -> {raw}; report -> {report}",
            file=sys.stderr,
        )
        return 3
    report.write_text(final.read_text())
    print(str(report))
    return 0


if __name__ == "__main__":
    sys.exit(main())
