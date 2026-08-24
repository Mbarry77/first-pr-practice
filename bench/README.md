# Machine capability benchmark

Answers one question with numbers instead of guesses: **which machine should
run a given parsing job, and how long will it take?**

Run it on each computer, then compare the two reports.

## What it measures

| Metric | Why it matters for parsing |
| --- | --- |
| CPU single core | The ceiling for anything single-threaded, which most naive parsers are |
| CPU all cores | What you actually gain by parallelizing — rarely the full core count |
| Memory copy | Parsing goes memory-bound long before CPU-bound once files leave cache |
| Disk write / read | Sequential throughput on a path you choose — point it at the array |
| **Parse throughput** | CSV, CSV-to-dicts, JSON-lines, and line counting, in MB/s |

The parse numbers are the point. Everything else explains them.

## Running it

**Windows:**
```powershell
cd "$HOME\github\first-pr-practice"
.\bench\bench.ps1
```

**Mac / Linux:**
```bash
cd ~/github/first-pr-practice
bash bench/bench.sh
```

Takes under a minute on a modern machine. Needs Python 3 — the scripts say how
to install it if it's missing. No packages, standard library only.

Useful flags (both platforms):

```
--disk-path <path>   run the disk test somewhere specific — use this to
                     measure a big array rather than the boot drive
--quick              smaller and faster
--skip-disk          inventory and CPU only
```

Windows uses `-DiskPath`, `-Quick`, `-SkipDisk`.

To measure the array rather than the system drive:

```powershell
.\bench\bench.ps1 -DiskPath D:\benchtmp
```
```bash
bash bench/bench.sh --disk-path /Volumes/Array/benchtmp
```

The disk test writes a temp file (512 MB by default), fsyncs it, reads it back,
and deletes it. It refuses to run if the target has less than twice that free.

## Comparing machines

Each run writes `bench-<hostname>.json`. Put both on one machine and:

```bash
python3 bench/compare.py bench-ALPHAX.json bench-macbook.json
```

You get every metric side by side, a projection of how long a 100 GB CSV job
would take on each (`--job-gb` to change the size), and a verdict on where bulk
work belongs — including the link speed at which shipping data to the faster
machine starts beating parsing it locally on the slower one.

## Reading the results

**Parallel speedup well under the core count** is normal and worth knowing.
Twenty-four cores rarely means 24x: memory bandwidth, and the coordination cost
of splitting work, eat into it. The benchmark measures your actual figure rather
than assuming the ideal.

**Disk read looks impossibly fast** because the file was just written and is
still in the OS page cache. The report labels it as an upper bound. The write
number is the honest one.

**The network line matters most for the 10G link.** A 10G adapter negotiating
at 1 Gb/s means a cable, switch port, or driver is holding it back — much easier
to catch here than to blame on slow code later.

## A caveat about the parse numbers

These measure **Python's** parsing speed, because Python is the usual reach for
this kind of work and it makes the two machines directly comparable.

Python's `csv` module is not fast in absolute terms. A columnar engine — DuckDB,
Polars, Arrow — will typically beat these numbers by one to two orders of
magnitude *on the same hardware*, because they parse in vectorized native code
instead of building a Python object per field.

So read the results as a comparison **between your machines**, not as the speed
limit of either one. If a job looks too slow here, changing the tool is usually
a much bigger win than changing the machine.
