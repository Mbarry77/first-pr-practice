#!/usr/bin/env bash
#
# Machine capability benchmark - macOS / Linux wrapper.
#
#   ./bench.sh                              # default
#   ./bench.sh --disk-path /Volumes/Array   # measure the big array instead
#   ./bench.sh --quick
#
# Collects hardware inventory the OS knows about, then hands off to
# bench_core.py for the measurements that must be identical across machines.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JSON_OUT="bench-$(hostname -s | tr -cd '[:alnum:]-').json"
PASSTHRU=()

while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON_OUT="$2"; shift 2 ;;
    *) PASSTHRU+=("$1"); shift ;;
  esac
done

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
row() { printf '    %-22s %s\n' "$1" "$2"; }

case "$(uname -s)" in
  Darwin*) OS=macos ;;
  Linux*)  OS=linux ;;
  *)       OS=other ;;
esac

# ------------------------------------------------------------------ inventory

say 'HARDWARE'

if [ "$OS" = macos ]; then
  row 'Model'    "$(sysctl -n hw.model 2>/dev/null || echo unknown)"
  row 'CPU'      "$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)"
  row 'Cores'    "$(sysctl -n hw.physicalcpu 2>/dev/null || echo '?') physical, $(sysctl -n hw.logicalcpu 2>/dev/null || echo '?') logical"
  # Apple Silicon splits cores into performance and efficiency; a parser pinned
  # to efficiency cores runs several times slower, so the split is worth seeing.
  if perf=$(sysctl -n hw.perflevel0.logicalcpu 2>/dev/null); then
    row 'Core split' "$perf performance, $(sysctl -n hw.perflevel1.logicalcpu 2>/dev/null || echo 0) efficiency"
  fi
  if mem=$(sysctl -n hw.memsize 2>/dev/null); then
    row 'RAM total' "$(awk -v b="$mem" 'BEGIN{printf "%.1f GB", b/1e9}')"
  fi
  row 'OS' "$(sw_vers -productName 2>/dev/null || echo macOS) $(sw_vers -productVersion 2>/dev/null || echo '')"
elif [ "$OS" = linux ]; then
  row 'CPU'   "$(awk -F: '/model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null | sed 's/^ *//' || echo unknown)"
  row 'Cores' "$(nproc 2>/dev/null || echo '?') logical"
  if kb=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null); then
    row 'RAM total' "$(awk -v k="$kb" 'BEGIN{printf "%.1f GB", k/1e6}')"
  fi
  row 'OS' "$(uname -sr)"
fi

say 'STORAGE'
if [ "$OS" = macos ]; then
  df -H / "${TMPDIR:-/tmp}" 2>/dev/null | tail -n +2 \
    | awk '!seen[$9]++ {printf "    %-22s %s used of %s (%s free)\n", $9, $3, $2, $4}'
  # Spinning vs solid state changes the disk numbers by an order of magnitude.
  if command -v system_profiler >/dev/null 2>&1; then
    system_profiler SPNVMeDataType SPSerialATADataType 2>/dev/null \
      | awk -F: '/Model:|Capacity:|Medium Type:/{gsub(/^ +/,"",$1);gsub(/^ +/,"",$2);printf "    %-22s %s\n",$1,$2}' \
      | head -12 || true
  fi
else
  df -h / "${TMPDIR:-/tmp}" 2>/dev/null | tail -n +2 \
    | awk '!seen[$6]++ {printf "    %-22s %s used of %s (%s avail)\n", $6, $3, $2, $4}'
fi

say 'NETWORK'
# The negotiated link rate. A 10G port running at 1000baseT means a cable,
# switch port, or driver is holding it back - catch that before blaming code.
if [ "$OS" = macos ]; then
  for iface in $(ifconfig -l 2>/dev/null | tr ' ' '\n' | grep -E '^(en|bridge)' || true); do
    status=$(ifconfig "$iface" 2>/dev/null | awk '/status:/{print $2}')
    [ "$status" = active ] || continue
    media=$(ifconfig "$iface" 2>/dev/null | awk -F'media: ' '/media:/{print $2; exit}')
    row "$iface" "${media:-unknown}"
  done
else
  for iface in /sys/class/net/*; do
    name=$(basename "$iface")
    [ "$name" = lo ] && continue
    [ "$(cat "$iface/operstate" 2>/dev/null)" = up ] || continue
    speed=$(cat "$iface/speed" 2>/dev/null || echo '')
    case "$speed" in
      ''|-1|0) row "$name" 'link rate not reported (virtual adapter?)' ;;
      *)       row "$name" "$(awk -v s="$speed" 'BEGIN{if(s>=1000) printf "%g Gb/s", s/1000; else printf "%d Mb/s", s}')" ;;
    esac
  done
fi

# -------------------------------------------------------------------- python

PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys; sys.exit(0 if sys.version_info[0]==3 else 1)' 2>/dev/null; then
    PY="$candidate"; break
  fi
done

if [ -z "$PY" ]; then
  cat <<'EOM'

Python 3 is not installed - the measurement half needs it.

  macOS:  xcode-select --install     (or: brew install python)
  Linux:  sudo apt-get install -y python3

Then re-run this script.
EOM
  exit 1
fi
say 'SOFTWARE'
row 'Python' "$("$PY" --version 2>&1)"

# ---------------------------------------------------------------- measurements

CORE="$SCRIPT_DIR/bench_core.py"
[ -f "$CORE" ] || { echo "bench_core.py not found next to this script ($CORE)" >&2; exit 1; }

say 'MEASUREMENTS'
"$PY" "$CORE" --json "$JSON_OUT" ${PASSTHRU[@]+"${PASSTHRU[@]}"}

printf '\033[0;32mSend %s back to compare against the other machine.\033[0m\n\n' "$JSON_OUT"
