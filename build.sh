#!/usr/bin/env bash
# Build the ppe-nss (NSS offload) image for the Arcadyan AW1000.
# Prepared tree: ./openwrt (openwrt-ppe-nss @ ppe-nss), ./builder (Qualcommax_NSS_Builder).
# Run this only after ./prepare.sh has completed.
set -euo pipefail
cd "$(dirname "$0")"

# Some launchers (CI runners, nohup wrappers) inherit SIGCHLD=SIG_IGN, which
# makes GNU make's wait() return ECHILD and die with
#   make: *** wait: No child processes.  Stop.
# Re-exec once with default dispositions so -j works everywhere.
if [ "${AW1000_SIGNAL_RESET:-0}" != 1 ]; then
    export AW1000_SIGNAL_RESET=1
    exec python3 -c 'import os,signal,sys; [signal.signal(s, signal.SIG_DFL) for s in (signal.SIGCHLD, signal.SIGPIPE, signal.SIGINT)]; os.execv(sys.argv[1], sys.argv[1:])' "$0" "$@"
fi

OPENWRT="$PWD/openwrt"
JOBS="${JOBS:-2}"          # 4 threads / 5.8 GB RAM: 2 is the safe parallelism, LTO+mold eats RAM
LOG="$PWD/build.log"

cd "$OPENWRT"
export TZ=UTC LC_ALL=C
export KBUILD_BUILD_USER=builder KBUILD_BUILD_HOST=aw1000-nss
export SOURCE_DATE_EPOCH="$(git show -s --format=%ct HEAD 2>/dev/null || date +%s)"
mkdir -p dl

echo "== download =="
make -j"$JOBS" download || { echo "download failed (rerun: make -j1 download V=s)" >&2; exit 1; }

echo "== build (jobs=$JOBS) =="
set +e
make -j"$JOBS" 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}
set -e
if [ "$rc" -ne 0 ]; then
    echo "BUILD FAILED rc=$rc — full log: $LOG" >&2
    echo "Retry the failing package verbosely: make V=s package/feeds/<feed>/<pkg>/compile" >&2
    exit "$rc"
fi

echo "== images =="
find bin/targets/qualcommax/ipq807x -maxdepth 1 -name '*aw1000*sysupgrade*' -printf '%f  %s bytes\n'

# Name the release (BYTE 1.0.x) and write its notes. Nothing is uploaded.
if [[ -x "$PWD/../builder/local/stage-release.sh" ]]; then
    echo "== release =="
    "$PWD/../builder/local/stage-release.sh"
fi
