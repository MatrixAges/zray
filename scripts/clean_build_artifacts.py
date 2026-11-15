"""Prune historical build verification outputs from this repository."""

import argparse
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import time


ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / ".zig-cache"
HISTORY = CACHE / "cold-build-analysis"
DOC_SUFFIXES = {".gz", ".json", ".jsonl", ".log", ".txt"}
CACHE_KEYS = {
    "bootstrap-functions": re.compile(r"[0-9a-f]{64}\.cache"),
    "c": re.compile(r"[0-9a-f]{32}"),
    "h": re.compile(r"[0-9a-f]{32}"),
    "o": re.compile(r"[0-9a-f]{32}"),
    "tmp": re.compile(r"[0-9a-f]{16}"),
    "z": re.compile(r"[0-9a-f]{32}"),
}


def git_paths(*args):
    output = subprocess.check_output(["git", "ls-files", "-z", *args], cwd=ROOT)
    return (ROOT / os.fsdecode(path) for path in output.split(b"\0") if path)


def expired_output(path, cutoff):
    metadata = path.lstat()
    if metadata.st_mtime >= cutoff:
        return False

    return not stat.S_ISDIR(metadata.st_mode) or all(
        expired_output(child, cutoff) for child in path.iterdir()
    )


def history_outputs():
    if not HISTORY.is_dir() or HISTORY.resolve() != HISTORY:
        return

    research = HISTORY / "ownership-research"
    yield from (path for path in HISTORY.iterdir() if path != research)

    if not research.is_dir() or research.is_symlink():
        return

    for workspace in research.iterdir():
        if workspace.is_dir() and not workspace.is_symlink():
            yield from workspace.iterdir()
        else:
            yield workspace


def old_history(cutoff, keep):
    for path in history_outputs():
        if not path.is_symlink() and not keep(path) and expired_output(path, cutoff):
            yield path


def package_caches():
    for package in (ROOT / "packages").iterdir():
        cache = package / ".zig-cache"
        if cache.is_dir() and cache.resolve() == cache:
            yield cache


def old_package_caches(caches, cutoff):
    for cache in caches:
        children = list(cache.iterdir())
        expired = [
            child for child in children
            if not child.is_symlink() and child.lstat().st_mtime < cutoff
        ]
        if cache.stat().st_mtime < cutoff and len(expired) == len(children):
            yield cache
        else:
            yield from expired


def unused_docs(cutoff):
    markdown = git_paths("-co", "--exclude-standard", "--", "*.md")
    references = "\n".join(
        path.read_text(encoding="utf-8", errors="replace")
        for path in set(markdown)
        if path.is_file() and not path.is_symlink()
    )
    for path in git_paths("--others", "--ignored", "--exclude-standard", "--", "docs"):
        if path.suffix not in DOC_SUFFIXES or path.resolve() != path or not path.is_file():
            continue

        if path.stat().st_mtime >= cutoff or path.name in references:
            continue

        parents = path.relative_to(ROOT / "docs").parts[1:-1]
        if not any(name + "/" in references or f"`{name}`" in references for name in parents):
            yield path


def expired_cache_entries(directory, cutoff):
    key = CACHE_KEYS[directory.name]
    with os.scandir(directory) as entries:
        for entry in entries:
            if not key.fullmatch(entry.name) or entry.is_symlink():
                continue

            try:
                modified = entry.stat(follow_symlinks=False).st_mtime
            except FileNotFoundError:
                continue
            if modified >= cutoff:
                continue

            path = Path(entry.path)
            if entry.is_dir(follow_symlinks=False) and any(
                child.lstat().st_mtime >= cutoff for child in path.iterdir()
            ):
                continue

            yield path


def remove(path):
    try:
        if path.is_dir() and not path.is_symlink():
            shutil.rmtree(path)
        else:
            path.unlink(missing_ok=True)
    except OSError as error:
        print(error, flush=True)
        return False
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="remove the selected outputs")
    parser.add_argument("--min-age-hours", type=float, default=6, help="minimum age in hours")
    parser.add_argument(
        "--keep",
        action="append",
        type=Path,
        default=[],
        help="active tool, output, or baseline path to retain (repeatable)",
    )
    options = parser.parse_args()
    if not 0 <= options.min_age_hours < float("inf"):
        parser.error("--min-age-hours must be finite and nonnegative")

    protected = [ROOT / "docs/user_request.jsonl", *((ROOT / path).resolve() for path in options.keep)]
    if any(not path.is_relative_to(ROOT) for path in protected):
        parser.error("--keep paths must be inside the repository")

    def keep(path):
        return any(path.is_relative_to(saved) or saved.is_relative_to(path) for saved in protected)

    cutoff = time.time() - options.min_age_hours * 3_600
    packages = list(package_caches())
    history = list(old_history(cutoff, keep))
    history.extend(path for path in old_package_caches(packages, cutoff) if not keep(path))
    retired = set(history)
    buckets = [
        cache / name
        for cache in (CACHE, *packages)
        if cache not in retired
        for name in CACHE_KEYS
        if (cache / name).is_dir()
        and (cache / name).resolve() == cache / name
        and cache / name not in retired
        and not keep(cache / name)
    ]
    files = [path for path in unused_docs(cutoff) if not keep(path)]
    print(
        f"Selected {len(history):,} historical outputs and {len(files):,} documents' intermediate files. "
        f"Scan {len(buckets):,} Zig cache directories for expired entries.",
        flush=True,
    )
    if not options.apply:
        for path in history[:12]:
            print(path.relative_to(ROOT))
        print("Run again with --apply to remove the selected outputs.")
        return

    before = shutil.disk_usage(ROOT).free
    errors = 0
    for index, path in enumerate(history, 1):
        errors += not remove(path)
        if index % 10 == 0:
            print(f"Processed {index:,}/{len(history):,} historical outputs.", flush=True)

    for path in files:
        errors += not remove(path)
    for directory in buckets:
        removed = 0
        for path in expired_cache_entries(directory, cutoff):
            success = remove(path)
            errors += not success
            removed += success
        if removed:
            print(f"Removed {removed:,} entries from {directory.relative_to(ROOT)}.", flush=True)
    free = shutil.disk_usage(ROOT).free
    print(
        f"Free space: {free / 2**30:.2f} GiB "
        f"({(free - before) / 2**30:+.2f} GiB during this run)."
    )
    return bool(errors)


if __name__ == "__main__":
    raise SystemExit(main())
