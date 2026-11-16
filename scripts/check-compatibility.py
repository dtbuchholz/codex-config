# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml>=6", "jsonschema>=4"]
# ///
"""Check maintained Codex configuration against the installed CLI and skill format."""

import argparse
import ast
import json
from pathlib import Path
import re
import subprocess
import sys
import tomllib

import yaml
from jsonschema import Draft7Validator


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--schema", type=Path, help="Optional downloaded Codex config schema")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    errors = []
    features_result = subprocess.run(
        ["codex", "features", "list"], capture_output=True, text=True, timeout=30
    )
    if features_result.returncode:
        print(features_result.stderr, file=sys.stderr)
        return 1
    features = {line.split()[0]: line.split()[1] for line in features_result.stdout.splitlines() if line.split()}
    schema = json.loads(args.schema.read_text()) if args.schema else None
    for filename in ("config.toml", "config.toml.template"):
        path = root / filename
        try:
            config = tomllib.loads(path.read_text())
            for name in config.get("features", {}):
                if name not in features or features[name] in {"removed", "deprecated"}:
                    errors.append(f"{filename}: unsupported or retired feature {name}")
            if schema:
                for error in Draft7Validator(schema).iter_errors(config):
                    errors.append(f"{filename}: {list(error.absolute_path)}: {error.message}")
        except (ValueError, OSError) as exc:
            errors.append(f"{filename}: {exc}")

    skills = sorted((root / "skills").glob("*/SKILL.md"))
    allowed = {"name", "description", "license", "allowed-tools", "metadata"}
    for path in skills:
        try:
            match = re.match(r"\A---\n(.*?)\n---(?:\n|$)", path.read_text(), re.S)
            if not match:
                raise ValueError("missing YAML frontmatter")
            metadata = yaml.safe_load(match[1])
            if not isinstance(metadata, dict):
                raise ValueError("frontmatter must be a mapping")
            if set(metadata) - allowed:
                raise ValueError(f"unsupported frontmatter: {sorted(set(metadata) - allowed)}")
            name, description = metadata.get("name"), metadata.get("description")
            if not isinstance(name, str) or not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", name) or len(name) > 64 or name != path.parent.name:
                raise ValueError("invalid or mismatched skill name")
            if not isinstance(description, str) or not description.strip() or len(description) > 1024:
                raise ValueError("description must be a nonempty string of at most 1024 characters")
        except (ValueError, OSError, yaml.YAMLError) as exc:
            errors.append(f"{path.relative_to(root)}: {exc}")

    agents = sorted((root / "agents").glob("*.toml"))
    names = set()
    for path in agents:
        try:
            agent = tomllib.loads(path.read_text())
            for key in ("name", "description", "developer_instructions"):
                if not isinstance(agent.get(key), str) or not agent[key].strip():
                    raise ValueError(f"missing {key}")
            if agent["name"] in names:
                raise ValueError(f"duplicate agent name {agent['name']}")
            names.add(agent["name"])
        except (ValueError, OSError) as exc:
            errors.append(f"{path.relative_to(root)}: {exc}")
    for path in (root / "agents").rglob("*.md"):
        errors.append(f"{path.relative_to(root)}: legacy Markdown agent; migrate to standalone TOML")

    scripts = sorted((root / "scripts").glob("*.sh")) + sorted((root / "skills").glob("*/scripts/*.sh"))
    for path in scripts:
        result = subprocess.run(["bash", "-n", str(path)], capture_output=True, text=True)
        if result.returncode:
            errors.append(f"{path.relative_to(root)}: {result.stderr.strip()}")
        for feature in re.findall(r"--(?:enable|disable)\s+([a-z][a-z0-9_]*)", path.read_text()):
            if feature not in features or features[feature] in {"removed", "deprecated"}:
                errors.append(f"{path.relative_to(root)}: unsupported or retired feature flag {feature}")

    python_scripts = sorted((root / "scripts").glob("*.py")) + sorted((root / "skills").glob("*/scripts/*.py"))
    for path in python_scripts:
        try:
            ast.parse(path.read_text(), filename=str(path))
        except SyntaxError as exc:
            errors.append(f"{path.relative_to(root)}: {exc}")

    for path in sorted((root / "policy").glob("*.rules")):
        result = subprocess.run(
            ["codex", "execpolicy", "check", "--rules", str(path), "git", "status"],
            capture_output=True, text=True, timeout=15,
        )
        if result.returncode:
            errors.append(f"{path.relative_to(root)}: {result.stderr.strip()}")

    # This starts and closes the config parser without making a model request.
    result = subprocess.run(
        ["codex", "app-server", "--strict-config", "--stdio"],
        input="", capture_output=True, text=True, timeout=30, cwd=root,
    )
    if result.returncode:
        errors.append(f"strict config startup: {result.stderr.strip()}")
    for error in errors:
        print(f"ERROR: {error}", file=sys.stderr)
    print(f"Checked 2 configs, {len(skills)} skills, {len(agents)} agents, {len(scripts)} scripts; {len(errors)} errors.")
    return bool(errors)


if __name__ == "__main__":
    sys.exit(main())
