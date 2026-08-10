#!/usr/bin/env python3
"""Check documentation conventions and internal links.

Three checks:

  1. Layout   — every markdown file lives in docs/, except README.md and
                Claude.md, which are conventionally read at the repo root.
  2. Links    — relative links point at files that exist.
  3. Anchors  — #fragments resolve to a heading in the target file.

Anchor slugs follow GitHub's rules: lowercase, strip anything that isn't a word
character/space/hyphen, spaces to hyphens, de-duplicate with -1, -2, ...

Usage: scripts/check-docs.py [--quiet]
Exits non-zero if anything fails.
"""

from __future__ import annotations

import re
import sys
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"
ROOT_ALLOWED = {"Claude.md", "README.md"}

# Skip anything vendored, generated, or fetched at runtime.
SKIP_DIRS = {".git", "_data", ".terraform", "node_modules", "scratchpad"}

# [text](target) — but not ![image](...) and not reference-style definitions.
LINK_RE = re.compile(r"(?<!!)\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
HEADING_RE = re.compile(r"^(#{1,6})\s+(.*?)\s*#*$")
# Fenced code blocks: their contents are not prose and must not be scanned.
FENCE_RE = re.compile(r"^\s*(```|~~~)")


def slugify(text: str) -> str:
    """Reproduce GitHub's heading-anchor algorithm closely enough to be useful."""
    # Strip inline markdown that does not survive into the rendered heading.
    text = re.sub(r"`([^`]*)`", r"\1", text)
    text = re.sub(r"\*\*([^*]*)\*\*", r"\1", text)
    text = re.sub(r"\*([^*]*)\*", r"\1", text)
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)

    text = unicodedata.normalize("NFKD", text)
    text = text.lower()
    # GitHub keeps word chars, spaces and hyphens; everything else is dropped.
    text = re.sub(r"[^\w\s-]", "", text, flags=re.UNICODE)
    return text.strip().replace(" ", "-")


def headings(path: Path) -> set[str]:
    """All anchor slugs a file offers, including duplicate-suffixed ones."""
    slugs: set[str] = set()
    counts: dict[str, int] = {}
    in_fence = False

    for line in path.read_text(encoding="utf-8").splitlines():
        if FENCE_RE.match(line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue

        m = HEADING_RE.match(line)
        if not m:
            continue

        base = slugify(m.group(2))
        if not base:
            continue
        n = counts.get(base, 0)
        slugs.add(base if n == 0 else f"{base}-{n}")
        counts[base] = n + 1

    return slugs


def links(path: Path) -> list[tuple[int, str]]:
    """(line number, target) for every inline link outside code fences."""
    found = []
    in_fence = False

    for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if FENCE_RE.match(line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        for m in LINK_RE.finditer(line):
            found.append((lineno, m.group(1)))

    return found


def markdown_files() -> list[Path]:
    return sorted(
        p
        for p in ROOT.rglob("*.md")
        if not SKIP_DIRS & set(p.relative_to(ROOT).parts)
    )


def main() -> int:
    quiet = "--quiet" in sys.argv
    errors: list[str] = []
    checked_links = 0

    files = markdown_files()
    if not files:
        print("error: no markdown files found", file=sys.stderr)
        return 1

    # --- 1. layout ---------------------------------------------------------
    for path in files:
        rel = path.relative_to(ROOT)
        if len(rel.parts) == 1:
            if rel.name not in ROOT_ALLOWED:
                errors.append(
                    f"{rel}: markdown at the repo root. Only {sorted(ROOT_ALLOWED)} "
                    f"may live outside docs/ — move it to docs/."
                )
        elif rel.parts[0] != "docs":
            errors.append(f"{rel}: markdown outside docs/ — move it to docs/.")

    # --- 2 & 3. links and anchors -----------------------------------------
    anchor_cache: dict[Path, set[str]] = {}

    for path in files:
        rel = path.relative_to(ROOT)

        for lineno, target in links(path):
            if target.startswith(("http://", "https://", "mailto:")):
                continue  # external; not checked offline

            checked_links += 1
            file_part, _, anchor = target.partition("#")

            if not file_part:
                dest = path  # same-file anchor
            else:
                dest = (path.parent / file_part).resolve()

            if not dest.exists():
                errors.append(f"{rel}:{lineno}: broken link -> {target}")
                continue

            if not anchor or dest.is_dir() or dest.suffix != ".md":
                continue

            if dest not in anchor_cache:
                anchor_cache[dest] = headings(dest)

            if anchor not in anchor_cache[dest]:
                errors.append(f"{rel}:{lineno}: no such anchor -> {target}")

    # --- report ------------------------------------------------------------
    if errors:
        print(f"docs check FAILED ({len(errors)} problem(s)):\n", file=sys.stderr)
        for e in errors:
            print(f"  {e}", file=sys.stderr)
        return 1

    if not quiet:
        print(
            f"docs check passed — {len(files)} file(s), {checked_links} internal link(s)"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
