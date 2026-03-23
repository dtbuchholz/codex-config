#!/usr/bin/env python3
"""Date-scoped recall helper for QMD conversation collections.

Usage examples:
  ~/.codex/scripts/qmd-temporal-recall.py "last Tuesday" "what did I do?"
  ~/.codex/scripts/qmd-temporal-recall.py "2026-02-24" "qmd node mismatch" --source codex
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from typing import Iterable


QMD_BIN = "qmd"
WEEKDAYS = {
    "monday": 0,
    "tuesday": 1,
    "wednesday": 2,
    "thursday": 3,
    "friday": 4,
    "saturday": 5,
    "sunday": 6,
}


@dataclass
class Hit:
    docid: str
    score: float
    path: str
    context: str
    rank_score: float


def normalize_date_phrase(phrase: str, today: date | None = None) -> str:
    today = today or datetime.now().date()
    raw = phrase.strip().lower()

    iso = re.fullmatch(r"\d{4}-\d{2}-\d{2}", raw)
    if iso:
        return raw

    if raw == "today":
        return today.isoformat()
    if raw == "yesterday":
        return (today - timedelta(days=1)).isoformat()

    m_last = re.fullmatch(r"last\s+([a-z]+)", raw)
    if m_last and m_last.group(1) in WEEKDAYS:
        target = WEEKDAYS[m_last.group(1)]
        delta = (today.weekday() - target) % 7
        if delta == 0:
            delta = 7
        return (today - timedelta(days=delta)).isoformat()

    if raw in WEEKDAYS:
        target = WEEKDAYS[raw]
        delta = (today.weekday() - target) % 7
        if delta == 0:
            delta = 7
        return (today - timedelta(days=delta)).isoformat()

    raise ValueError(
        f"Unsupported date phrase: {phrase!r}. Use YYYY-MM-DD, today, yesterday, or 'last Tuesday'."
    )


def list_collection_paths(collection: str) -> list[str]:
    cmd = [QMD_BIN, "ls", collection]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True)
    except FileNotFoundError as exc:
        raise RuntimeError("qmd CLI not found in PATH. Install QMD and retry.") from exc
    if proc.returncode != 0:
        raise RuntimeError(f"qmd ls failed for {collection}: {proc.stderr.strip()}")

    paths: list[str] = []
    for line in proc.stdout.splitlines():
        match = re.search(r"(qmd://\S+)$", line.strip())
        if not match:
            continue
        paths.append(match.group(1))
    return paths


def date_in_path(path: str, day: str) -> bool:
    return path.endswith(f"-{day}.md")


def keyword_overlap(query: str, text: str) -> int:
    tokens = [t for t in re.findall(r"[a-zA-Z0-9]+", query.lower()) if len(t) >= 4]
    if not tokens:
        return 0
    hay = text.lower()
    return sum(1 for tok in set(tokens) if tok in hay)


def docid_from_path(path: str) -> str:
    name = path.rsplit("/", 1)[-1]
    return name.rsplit(".", 1)[0]


def rank_hits(query: str, hits: Iterable[Hit]) -> list[Hit]:
    ranked: list[Hit] = []
    for h in hits:
        overlap = keyword_overlap(query, h.path + " " + h.context)
        h.rank_score = h.score + (0.1 * overlap)
        ranked.append(h)
    ranked.sort(key=lambda x: x.rank_score, reverse=True)
    return ranked


def qmd_get(path: str) -> str:
    cmd = [QMD_BIN, "get", path, "-l", "220"]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True)
    except FileNotFoundError:
        return ""
    if proc.returncode != 0:
        return ""
    return proc.stdout


def extract_section_bullets(text: str) -> dict[str, list[str]]:
    wanted = {
        "### Goals": [],
        "### Actions": [],
        "### Decisions": [],
        "### Issues And Risks": [],
        "## Final Turn Context": [],
    }
    current: str | None = None
    for raw in text.splitlines():
        line = raw.rstrip()
        if line in wanted:
            current = line
            continue
        if line.startswith("#"):
            current = None
            continue
        if current and line.startswith("- "):
            wanted[current].append(line[2:].strip())
    return wanted


def main() -> int:
    parser = argparse.ArgumentParser(description="Date-scoped QMD recall helper.")
    parser.add_argument("date_phrase", help="Date phrase: YYYY-MM-DD, today, yesterday, or last Tuesday")
    parser.add_argument("question", help="Question to match against date-scoped conversations")
    parser.add_argument("--source", choices=["codex", "claude", "both"], default="both")
    parser.add_argument("--top", type=int, default=6, help="Max number of session digests to return")
    args = parser.parse_args()

    try:
        day = normalize_date_phrase(args.date_phrase)
    except ValueError as e:
        print(f"Error: {e}", file=sys.stderr)
        return 2

    collections = []
    if args.source in ("codex", "both"):
        collections.append("codex-conversations")
    if args.source in ("claude", "both"):
        collections.append("claude-conversations")

    combined: list[Hit] = []
    for collection in collections:
        paths = list_collection_paths(collection)
        for path in paths:
            if not date_in_path(path, day):
                continue
            doc = qmd_get(path)
            overlap = keyword_overlap(args.question, doc)
            if overlap == 0 and args.question.strip().lower() not in ("what did i do?", "what did i do", "summary"):
                continue
            combined.append(
                Hit(
                    docid=docid_from_path(path),
                    score=float(overlap),
                    path=path,
                    context=f"overlap={overlap}",
                    rank_score=float(overlap),
                )
            )

    ranked = rank_hits(args.question, combined)
    top_hits = ranked[: args.top]

    print(f"Date: {day}")
    print(f"Collections: {', '.join(collections)}")
    print(f"Matches: {len(combined)}")
    print("")

    if not top_hits:
        print("No date-scoped matches found.")
        return 0

    for idx, hit in enumerate(top_hits, start=1):
        print(f"{idx}. {hit.path} (score={hit.rank_score:.2f})")
        doc = qmd_get(hit.path)
        sections = extract_section_bullets(doc)
        for label in ("### Goals", "### Actions", "### Decisions", "### Issues And Risks", "## Final Turn Context"):
            bullets = sections[label]
            if not bullets:
                continue
            print(f"   {label.replace('#', '').strip()}:")
            for item in bullets[:2]:
                print(f"   - {item}")
        print("")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
