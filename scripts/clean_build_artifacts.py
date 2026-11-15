"""Prune historical build verification outputs from this repository."""

import argparse
import fcntl
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import time


ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / ".zig-cache"
KEEP_FILE = CACHE / ".cleanup-keep"
HISTORY = CACHE / "cold-build-analysis"
VERIFICATION_GLOBAL = CACHE / "verification-global"
VERIFICATION_TEMP = CACHE / "verification-tmp"
DOC_SUFFIXES = {".gz", ".json", ".jsonl", ".log", ".txt"}
CACHE_KEYS = {
    "args": re.compile(r"[0-9a-f]{64}"),
    "b": re.compile(r"[0-9a-f]{32}"),
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
    try:
        metadata = path.lstat()
        if metadata.st_mtime >= cutoff:
            return False

        return not stat.S_ISDIR(metadata.st_mode) or all(
            expired_output(child, cutoff) for child in path.iterdir()
        )
    except FileNotFoundError:
        return False


def history_outputs():
    if VERIFICATION_TEMP.is_dir() and VERIFICATION_TEMP.resolve() == VERIFICATION_TEMP:
        yield from VERIFICATION_TEMP.iterdir()

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


def package_caches():
    for package in (ROOT / "packages").iterdir():
        cache = package / ".zig-cache"
        if cache.is_dir() and cache.resolve() == cache:
            yield cache


def install_outputs():
    for project in (ROOT, *(ROOT / "packages").iterdir()):
        output = project / "zig-out"
        if output.is_dir() and output.resolve() == output:
            yield output


def old_package_caches(caches, cutoff):
    for cache in caches:
        children = list(cache.iterdir())
        expired = [
            child for child in children
            if not child.is_symlink() and expired_output(child, cutoff)
        ]
        if cache.stat().st_mtime < cutoff and len(expired) == len(children):
            yield cache
        else:
            yield from expired


def cache_buckets(cache):
    for name in CACHE_KEYS:
        bucket = cache / name
        if bucket.is_dir() and bucket.resolve() == bucket:
            yield bucket


def history_cache_buckets(outputs, retained):
    for output in outputs:
        if output.is_symlink() or not output.is_dir() or retained(output):
            continue

        for directory, names, _ in os.walk(output):
            path = Path(directory)
            if retained(path):
                names.clear()
                continue

            if {"h", "o"}.issubset(names):
                buckets = list(cache_buckets(path))
                yield from buckets
                names[:] = [name for name in names if path / name not in buckets]


def documentation_references():
    markdown = git_paths("-co", "--exclude-standard", "--", "*.md")
    return "\n".join(
        path.read_text(encoding="utf-8", errors="replace")
        for path in set(markdown)
        if path.is_file() and not path.is_symlink()
    )


def unused_intermediate_files(cutoff, references):
    candidates = git_paths(
        "--others", "--ignored", "--exclude-standard", "--",
        "docs", ":(glob).zig-cache/*.log",
    )
    for path in candidates:
        if path.suffix not in DOC_SUFFIXES or path.resolve() != path or not path.is_file():
            continue

        if path.stat().st_mtime >= cutoff or path.name in references:
            continue

        if path.parent == CACHE:
            yield path
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
            if entry.is_dir(follow_symlinks=False) and not expired_output(path, cutoff):
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


def clean(options, protected):
    def retained(path):
        return any(path.is_relative_to(saved) for saved in protected)

    def keep(path):
        return retained(path) or any(saved.is_relative_to(path) for saved in protected)

    cutoff = time.time() - options.min_age_hours * 3_600
    references = documentation_references()
    packages = list(package_caches())
    outputs = list(history_outputs())
    history = [
        path for path in (*outputs, *install_outputs())
        if not path.is_symlink() and not keep(path)
        and (not path.is_file() or path.name not in references)
        and expired_output(path, cutoff)
    ]
    history.extend(path for path in old_package_caches(packages, cutoff) if not keep(path))
    retired = set(history)
    buckets = [
        bucket
        for cache in (CACHE, VERIFICATION_GLOBAL, *packages)
        if cache not in retired
        for bucket in cache_buckets(cache)
    ]
    buckets.extend(history_cache_buckets((path for path in outputs if path not in retired), retained))
    buckets = [bucket for bucket in buckets if bucket not in retired and not retained(bucket)]
    files = [path for path in unused_intermediate_files(cutoff, references) if not keep(path)]
    print(
        f"Selected {len(history):,} historical outputs and {len(files):,} intermediate files. "
        f"Scanning {len(buckets):,} Zig cache directories for expired entries.",
        flush=True,
    )
    if not options.apply:
        for path in (*history, *files):
            print(path.relative_to(ROOT))

    before = shutil.disk_usage(ROOT).free
    errors = 0
    if options.apply:
        for index, path in enumerate(history, 1):
            if path.exists() and expired_output(path, cutoff):
                errors += not remove(path)
            if index % 10 == 0:
                print(f"Processed {index:,}/{len(history):,} historical outputs.", flush=True)

        for path in files:
            if path.exists() and expired_output(path, cutoff):
                errors += not remove(path)

    for directory in buckets:
        count = 0
        for path in expired_cache_entries(directory, cutoff):
            if keep(path):
                continue

            success = not options.apply or remove(path)
            errors += not success
            count += success

        if count:
            action = "Removed" if options.apply else "Selected"
            print(f"{action} {count:,} entries from {directory.relative_to(ROOT)}.", flush=True)

    if not options.apply:
        print("Run again with --apply to remove the selected outputs.")
        return

    free = shutil.disk_usage(ROOT).free
    print(
        f"Free space: {free / 2**30:.2f} GiB "
        f"({(free - before) / 2**30:+.2f} GiB during this run)."
    )
    return bool(errors)


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

    if CACHE.resolve() != CACHE:
        parser.error(".zig-cache must be inside the repository")

    if KEEP_FILE.is_symlink():
        parser.error(f"{KEEP_FILE.relative_to(ROOT)} must be a local file")

    pinned = []
    if KEEP_FILE.is_file():
        pinned = [line for line in KEEP_FILE.read_text(encoding="utf-8").splitlines() if line]

    protected = {(ROOT / path).resolve() for path in (*pinned, *options.keep)}
    if any(path == ROOT or not path.is_relative_to(ROOT) for path in protected):
        parser.error("retained paths must be specific paths inside the repository")

    for path in sorted(protected):
        if not path.exists():
            print(f"Retained path is missing: {path.relative_to(ROOT)}", flush=True)

    protected.update(git_paths(
        "--cached", "--", ".zig-cache", "zig-out",
        ":(glob)packages/*/.zig-cache/**", ":(glob)packages/*/zig-out/**",
    ))
    protected.add(ROOT / "docs/user_request.jsonl")

    if not options.apply:
        return clean(options, protected)

    CACHE.mkdir(exist_ok=True)
    with (CACHE / ".cleanup.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("Build artifact cleanup is already running.")
            return

        return clean(options, protected)


if __name__ == "__main__":
    raise SystemExit(main())
