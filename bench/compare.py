#!/usr/bin/env python3
"""Compare benchmark reports from two or more machines.

    python3 compare.py bench-ALPHAX.json bench-macbook.json

Prints each metric side by side, marks the winner, and turns the parsing
numbers into the only question that matters day to day: how long would this
machine take on a job of a given size, and which one should run it.
"""

import argparse
import json
import sys

# (json path, label, unit, higher_is_better)
METRICS = [
    (("cpu_single", "mops_per_sec"),      "CPU single core",   "Mops/s", True),
    (("cpu_multi", "mops_per_sec"),       "CPU all cores",     "Mops/s", True),
    (("cpu_scaling", "speedup"),          "Parallel speedup",  "x",      True),
    (("memory", "gb_per_sec"),            "Memory copy",       "GB/s",   True),
    (("disk", "write_mb_per_sec"),        "Disk write",        "MB/s",   True),
    (("disk", "read_mb_per_sec"),         "Disk read (cached)", "MB/s",  True),
    (("parse", "line_count", "mb_per_sec"),     "Line counting", "MB/s", True),
    (("parse", "csv_reader", "mb_per_sec"),     "CSV parse",     "MB/s", True),
    (("parse", "csv_dictreader", "mb_per_sec"), "CSV to dicts",  "MB/s", True),
    (("parse", "json_lines", "mb_per_sec"),     "JSON lines",    "MB/s", True),
]


def dig(report, path):
    node = report
    for key in path:
        if not isinstance(node, dict) or key not in node:
            return None
        node = node[key]
    return node if isinstance(node, (int, float)) else None


def load(paths):
    reports = []
    for path in paths:
        try:
            with open(path) as fh:
                data = json.load(fh)
        except (OSError, json.JSONDecodeError) as exc:
            sys.exit(f"could not read {path}: {exc}")
        label = data.get("system", {}).get("hostname") or path
        reports.append((label, data))
    return reports


def main():
    ap = argparse.ArgumentParser(description="Compare machine benchmarks")
    ap.add_argument("reports", nargs="+", help="bench-*.json files")
    ap.add_argument("--job-gb", type=float, default=100,
                    help="job size to project, in GB (default 100)")
    args = ap.parse_args()

    reports = load(args.reports)
    if len(reports) < 2:
        sys.exit("give at least two reports to compare")

    width = max(14, max(len(label) for label, _ in reports) + 2)

    print("\n" + "=" * (26 + width * len(reports)))
    print("  MACHINE COMPARISON")
    print("=" * (26 + width * len(reports)))

    header = f"  {'':<24}"
    for label, _ in reports:
        header += f"{label:>{width}}"
    print(header)

    print(f"  {'':<24}" + "".join(
        f"{data.get('system', {}).get('cpu_logical', '?'):>{width - 6}} cores"
        for _, data in reports))
    print("-" * (26 + width * len(reports)))

    for path, label, unit, higher in METRICS:
        values = [dig(data, path) for _, data in reports]
        present = [v for v in values if v is not None]
        if not present:
            continue
        best = max(present) if higher else min(present)
        line = f"  {label:<24}"
        for v in values:
            if v is None:
                line += f"{'n/a':>{width}}"
            else:
                mark = " *" if v == best and len(present) > 1 else "  "
                line += f"{v:>{width - 2}.1f}{mark}"
        print(line + f"  {unit}")

    # ------------------------------------------------------------- projection
    print("\n" + "-" * (26 + width * len(reports)))
    print(f"  TIME TO PARSE {args.job_gb:g} GB OF CSV")
    print("-" * (26 + width * len(reports)))

    def fmt(minutes):
        if minutes < 60:
            return f"{minutes:.1f} min"
        return f"{minutes / 60:.1f} hr"

    single_times, multi_times = [], []
    for label, data in reports:
        rate = dig(data, ("parse", "csv_reader", "mb_per_sec"))
        speedup = dig(data, ("cpu_scaling", "speedup")) or 1.0
        if not rate:
            single_times.append(None)
            multi_times.append(None)
            continue
        mb = args.job_gb * 1024
        single_times.append(mb / rate / 60)
        multi_times.append(mb / (rate * speedup) / 60)

    for name, times in (("one core", single_times), ("all cores", multi_times)):
        line = f"  {name:<24}"
        good = [t for t in times if t is not None]
        best = min(good) if good else None
        for t in times:
            if t is None:
                line += f"{'n/a':>{width}}"
            else:
                mark = " *" if t == best and len(good) > 1 else "  "
                line += f"{fmt(t):>{width - 2}}{mark}"
        print(line)

    # ----------------------------------------------------------------- verdict
    print("\n" + "-" * (26 + width * len(reports)))
    print("  VERDICT")
    print("-" * (26 + width * len(reports)))

    scored = [(label, data, dig(data, ("parse", "csv_reader", "mb_per_sec")),
               dig(data, ("cpu_scaling", "speedup")) or 1.0)
              for label, data in reports]
    scored = [s for s in scored if s[2]]
    if not scored:
        print("  no parsing numbers to compare")
        return

    by_bulk = sorted(scored, key=lambda s: s[2] * s[3], reverse=True)
    by_single = sorted(scored, key=lambda s: s[2], reverse=True)

    bulk_winner = by_bulk[0]
    runner_up = by_bulk[1] if len(by_bulk) > 1 else None
    ratio = (bulk_winner[2] * bulk_winner[3]) / (runner_up[2] * runner_up[3]) if runner_up else 1

    print(f"  Bulk parsing        -> {bulk_winner[0]}", end="")
    if runner_up:
        print(f"  ({ratio:.1f}x faster than {runner_up[0]})")
    else:
        print()
    print(f"  Single-file / quick -> {by_single[0][0]}")

    if runner_up and ratio < 1.3:
        print("\n  These are close enough that either can do the work;")
        print("  pick on where the data already lives, not on speed.")
    else:
        print(f"\n  Run bulk jobs on {bulk_winner[0]} and keep the data local to it.")
        print("  Moving data across the network to the faster machine only pays")
        print("  off if the link beats the slower machine's parse rate.")

    # Network break-even: at what link speed does shipping data elsewhere win?
    if runner_up:
        slower_rate = runner_up[2]
        print(f"\n  Break-even: sending data to {bulk_winner[0]} beats parsing")
        print(f"  locally on {runner_up[0]} only above ~{slower_rate * 8 / 1000:.1f} Gb/s of")
        print("  sustained transfer, before protocol overhead.")
    print()


if __name__ == "__main__":
    main()
