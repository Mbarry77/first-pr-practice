#!/usr/bin/env python3
"""Cross-platform capability benchmark, aimed at large local parsing work.

Runs the same measurements on every machine so the results can be compared
directly. Standard library only - nothing to install.

    python3 bench_core.py                     # default sizes
    python3 bench_core.py --disk-path /Volumes/BigArray
    python3 bench_core.py --quick             # smaller, faster
    python3 bench_core.py --json report.json

What it measures, and why it matters for parsing:

  cpu_single   One core chewing through a tight loop. Sets the ceiling for
               anything single-threaded, which most naive parsers are.
  cpu_multi    The same loop on every core at once. The gap between this and
               cpu_single x cores is what you actually gain by parallelizing.
  memory       Large-buffer copy throughput. Parsing is memory-bound long
               before it is CPU-bound once files stop fitting in cache.
  disk         Sequential write (fsynced) and read on a chosen path. Point
               --disk-path at the big array to measure the array, not the
               boot drive.
  parse        The real question: CSV, JSON-lines, and plain line counting,
               measured in MB/s against a generated corpus.
"""

import argparse
import csv
import io
import json
import multiprocessing
import os
import platform
import random
import shutil
import statistics
import sys
import tempfile
import time

SCHEMA_VERSION = 2


# --------------------------------------------------------------------- helpers

def human(n, unit="B"):
    """Bytes to a readable string. 1536 -> '1.50 KB'."""
    step = 1024.0
    for prefix in ("", "K", "M", "G", "T"):
        if abs(n) < step or prefix == "T":
            return f"{n:.2f} {prefix}{unit}"
        n /= step


def best_of(fn, rounds):
    """Run fn() a few times, return (best_seconds, all_seconds).

    Best-of rather than mean: the fastest run is the one least polluted by
    other processes, which is what we want when comparing two machines that
    are not idle in the same way.
    """
    times = []
    for _ in range(rounds):
        start = time.perf_counter()
        fn()
        times.append(time.perf_counter() - start)
    return min(times), times


# ------------------------------------------------------------------------ cpu

def cpu_kernel(iterations):
    """A deterministic integer loop. Pure Python on purpose.

    Measuring raw FLOPS would say little about parsing throughput; what
    matters is how fast this machine drives the interpreter, since that is
    what a Python parser is bound by.
    """
    x = 12345
    for _ in range(iterations):
        x = (x * 1664525 + 1013904223) & 0xFFFFFFFF
        x ^= x >> 13
    return x


def _worker(iterations):
    return cpu_kernel(iterations)


def bench_cpu_single(iterations, rounds):
    best, _ = best_of(lambda: cpu_kernel(iterations), rounds)
    return {
        "iterations": iterations,
        "seconds": round(best, 4),
        "mops_per_sec": round(iterations / best / 1e6, 2),
    }


def bench_cpu_multi(iterations, workers, rounds):
    """Same kernel on every core at once, to expose real parallel scaling."""
    def run():
        with multiprocessing.Pool(workers) as pool:
            pool.map(_worker, [iterations] * workers)

    best, _ = best_of(run, rounds)
    total = iterations * workers
    return {
        "workers": workers,
        "iterations_total": total,
        "seconds": round(best, 4),
        "mops_per_sec": round(total / best / 1e6, 2),
    }


# --------------------------------------------------------------------- memory

def bench_memory(size_mb, rounds):
    size = size_mb * 1024 * 1024
    src = bytearray(os.urandom(min(size, 8 * 1024 * 1024)))
    src = bytearray(bytes(src) * (size // len(src)))
    dst = bytearray(len(src))

    def run():
        dst[:] = src

    best, _ = best_of(run, rounds)
    return {
        "buffer_mb": round(len(src) / 1024 / 1024, 1),
        "seconds": round(best, 4),
        "gb_per_sec": round(len(src) / best / 1e9, 2),
    }


# ----------------------------------------------------------------------- disk

def bench_disk(path, size_mb):
    """Sequential write (with fsync) then read, on the given filesystem.

    The read number is optimistic: the file was just written, so some of it
    is still in the OS page cache. Treat write as the honest figure and read
    as an upper bound. Dropping caches portably is not possible without root.
    """
    os.makedirs(path, exist_ok=True)
    free = shutil.disk_usage(path).free
    need = size_mb * 1024 * 1024 * 2
    if free < need:
        return {"error": f"needs {human(need)} free, has {human(free)}"}

    chunk = os.urandom(4 * 1024 * 1024)
    chunks = (size_mb * 1024 * 1024) // len(chunk)
    total = chunks * len(chunk)
    fd, tmp = tempfile.mkstemp(dir=path, prefix=".benchio-")
    os.close(fd)

    try:
        start = time.perf_counter()
        with open(tmp, "wb") as fh:
            for _ in range(chunks):
                fh.write(chunk)
            fh.flush()
            os.fsync(fh.fileno())
        write_s = time.perf_counter() - start

        start = time.perf_counter()
        with open(tmp, "rb") as fh:
            while fh.read(4 * 1024 * 1024):
                pass
        read_s = time.perf_counter() - start
    finally:
        try:
            os.remove(tmp)
        except OSError:
            pass

    return {
        "path": os.path.abspath(path),
        "size_mb": round(total / 1024 / 1024, 1),
        "write_mb_per_sec": round(total / write_s / 1024 / 1024, 1),
        "read_mb_per_sec": round(total / read_s / 1024 / 1024, 1),
        "read_note": "page cache warm - upper bound, not a cold-read figure",
    }


# ---------------------------------------------------------------------- parse

def make_corpus(rows, seed=1234):
    """Build matching CSV and JSON-lines corpora in memory."""
    rnd = random.Random(seed)
    words = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf"]
    csv_buf = io.StringIO()
    writer = csv.writer(csv_buf, lineterminator="\n")
    writer.writerow(["id", "name", "category", "amount", "ts", "note"])
    json_lines = []
    for i in range(rows):
        record = {
            "id": i,
            "name": f"{rnd.choice(words)}-{rnd.randrange(100000)}",
            "category": rnd.choice(words),
            "amount": round(rnd.uniform(0, 10000), 2),
            "ts": 1700000000 + i,
            "note": rnd.choice(words) * rnd.randrange(1, 4),
        }
        writer.writerow(list(record.values()))
        json_lines.append(json.dumps(record))
    return csv_buf.getvalue(), "\n".join(json_lines) + "\n"


def bench_parse(rows, rounds):
    csv_text, json_text = make_corpus(rows)
    csv_bytes = len(csv_text.encode())
    json_bytes = len(json_text.encode())

    def count_lines():
        n = 0
        for _ in io.StringIO(csv_text):
            n += 1
        return n

    def parse_csv():
        total = 0.0
        for row in csv.reader(io.StringIO(csv_text)):
            total += 1
        return total

    def parse_csv_dict():
        total = 0.0
        for row in csv.DictReader(io.StringIO(csv_text)):
            total += float(row["amount"])
        return total

    def parse_json():
        total = 0.0
        for line in io.StringIO(json_text):
            total += json.loads(line)["amount"]
        return total

    results = {}
    for label, fn, nbytes in (
        ("line_count", count_lines, csv_bytes),
        ("csv_reader", parse_csv, csv_bytes),
        ("csv_dictreader", parse_csv_dict, csv_bytes),
        ("json_lines", parse_json, json_bytes),
    ):
        best, _ = best_of(fn, rounds)
        results[label] = {
            "seconds": round(best, 4),
            "mb_per_sec": round(nbytes / best / 1024 / 1024, 1),
            "rows_per_sec": int(rows / best),
        }

    results["corpus"] = {
        "rows": rows,
        "csv_mb": round(csv_bytes / 1024 / 1024, 2),
        "json_mb": round(json_bytes / 1024 / 1024, 2),
    }
    return results


# --------------------------------------------------------------------- system

def system_info():
    try:
        logical = os.cpu_count() or 0
    except NotImplementedError:
        logical = 0
    info = {
        "hostname": platform.node(),
        "os": platform.system(),
        "os_release": platform.release(),
        "machine": platform.machine(),
        "processor": platform.processor() or "unknown",
        "python": platform.python_version(),
        "python_impl": platform.python_implementation(),
        "cpu_logical": logical,
    }
    # RAM, where the platform offers it without extra dependencies.
    try:
        if hasattr(os, "sysconf") and "SC_PAGE_SIZE" in os.sysconf_names:
            pages = os.sysconf("SC_PHYS_PAGES")
            info["ram_total_gb"] = round(pages * os.sysconf("SC_PAGE_SIZE") / 1e9, 1)
    except (ValueError, OSError):
        pass
    return info


# ----------------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description="Machine capability benchmark")
    ap.add_argument("--disk-path", default=None,
                    help="where to run the disk test (default: system temp). "
                         "Point this at the big array to measure the array.")
    ap.add_argument("--disk-mb", type=int, default=512)
    ap.add_argument("--memory-mb", type=int, default=256)
    ap.add_argument("--parse-rows", type=int, default=400000)
    ap.add_argument("--cpu-iterations", type=int, default=3000000)
    ap.add_argument("--rounds", type=int, default=3)
    ap.add_argument("--quick", action="store_true", help="smaller and faster")
    ap.add_argument("--json", default=None, help="also write the report here")
    ap.add_argument("--skip-disk", action="store_true")
    args = ap.parse_args()

    if args.quick:
        args.disk_mb = 128
        args.memory_mb = 128
        args.parse_rows = 100000
        args.cpu_iterations = 1000000
        args.rounds = 2

    workers = os.cpu_count() or 1
    report = {"schema": SCHEMA_VERSION, "system": system_info()}

    print("=" * 62)
    print(f"  {report['system']['hostname']}  ({report['system']['os']} "
          f"{report['system']['machine']}, {workers} logical cores)")
    print("=" * 62)

    print("\n[1/5] CPU, single core ...", end="", flush=True)
    report["cpu_single"] = bench_cpu_single(args.cpu_iterations, args.rounds)
    print(f" {report['cpu_single']['mops_per_sec']} Mops/s")

    print(f"[2/5] CPU, {workers} cores ...", end="", flush=True)
    report["cpu_multi"] = bench_cpu_multi(args.cpu_iterations, workers, args.rounds)
    print(f" {report['cpu_multi']['mops_per_sec']} Mops/s")

    single = report["cpu_single"]["mops_per_sec"]
    multi = report["cpu_multi"]["mops_per_sec"]
    report["cpu_scaling"] = {
        "speedup": round(multi / single, 2) if single else None,
        "efficiency_pct": round(100 * (multi / single) / workers, 1) if single else None,
    }
    print(f"      -> {report['cpu_scaling']['speedup']}x "
          f"({report['cpu_scaling']['efficiency_pct']}% of linear)")

    print(f"[3/5] Memory copy ...", end="", flush=True)
    report["memory"] = bench_memory(args.memory_mb, args.rounds)
    print(f" {report['memory']['gb_per_sec']} GB/s")

    if args.skip_disk:
        report["disk"] = {"skipped": True}
        print("[4/5] Disk ... skipped")
    else:
        path = args.disk_path or tempfile.gettempdir()
        print(f"[4/5] Disk at {path} ...", end="", flush=True)
        report["disk"] = bench_disk(path, args.disk_mb)
        if "error" in report["disk"]:
            print(f" SKIPPED: {report['disk']['error']}")
        else:
            print(f" write {report['disk']['write_mb_per_sec']} MB/s, "
                  f"read {report['disk']['read_mb_per_sec']} MB/s")

    print(f"[5/5] Parsing ...", end="", flush=True)
    report["parse"] = bench_parse(args.parse_rows, args.rounds)
    print(f" csv {report['parse']['csv_reader']['mb_per_sec']} MB/s, "
          f"json {report['parse']['json_lines']['mb_per_sec']} MB/s")

    print("\n" + "-" * 62)
    print("  PARSING THROUGHPUT (the number that decides where work runs)")
    print("-" * 62)
    for label in ("line_count", "csv_reader", "csv_dictreader", "json_lines"):
        r = report["parse"][label]
        print(f"    {label:<16} {r['mb_per_sec']:>8} MB/s   "
              f"{r['rows_per_sec']:>12,} rows/s")

    csv_rate = report["parse"]["csv_reader"]["mb_per_sec"]
    if csv_rate:
        for size_gb in (1, 10, 100):
            secs = size_gb * 1024 / csv_rate
            print(f"    {size_gb:>3} GB CSV, single core: {secs/60:8.1f} min")
        eff = report["cpu_scaling"]["speedup"] or 1
        secs = 100 * 1024 / (csv_rate * eff)
        print(f"    100 GB CSV, all {workers} cores:  {secs/60:8.1f} min")

    if args.json:
        with open(args.json, "w") as fh:
            json.dump(report, fh, indent=2)
        print(f"\n  JSON report written to {args.json}")

    print()
    return report


if __name__ == "__main__":
    multiprocessing.freeze_support()   # required on Windows
    main()
