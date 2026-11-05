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
# SMOKE=1 compiles tools + toolchain + kernel + the vendor MHI module before
# the long world build. It costs nothing extra when it passes (the stamps are
# reused) and makes a broken kernel module fail in about an hour instead of
# four. SMOKE=0 skips it.
SMOKE="${SMOKE:-1}"

cd "$OPENWRT"
export TZ=UTC LC_ALL=C
export KBUILD_BUILD_USER=builder KBUILD_BUILD_HOST=aw1000-nss
export SOURCE_DATE_EPOCH="$(git show -s --format=%ct HEAD 2>/dev/null || date +%s)"
mkdir -p dl
: >"$LOG"

# Verbosity matters more than it looks: with no V=, include/verbose.mk runs
# every sub-make as
#   cmd() { >/dev/null 2>&1 make -s "$@" </dev/null || { echo "re-run with V=s"; false; }; }
# so ALL compiler output -- including the real error -- is thrown away and the
# log only says "package/X failed to build". V=s switches SUBMAKE back to
# $(MAKE) -w, which keeps the compiler diagnostics. V=sc also echoes commands.
echo "== download =="
make -j"$JOBS" V=s download || { echo "download failed; rerun: make -j1 V=s download" >&2; exit 1; }

if [ "$SMOKE" != 0 ]; then
    echo "== smoke: tools, toolchain, kernel, then the vendor MHI module (V=sc) =="
    for goal in tools/install toolchain/install target/compile \
                package/feeds/qmodem/quectel_MHI/compile; do
        echo "-- smoke: $goal"
        make -j"$JOBS" V=sc "$goal" 2>&1 | tee -a "$LOG"
    done
    echo "== smoke ok =="
fi

echo "== build (jobs=$JOBS) =="
set +e
make -j"$JOBS" V=s 2>&1 | tee -a "$LOG"
rc=${PIPESTATUS[0]}
set -e
if [ "$rc" -ne 0 ]; then
    echo "BUILD FAILED rc=$rc — full log: $LOG" >&2
    # "ERROR: package/feeds/qmodem/quectel_MHI failed to build." names the
    # builddir that broke. Rebuild it alone at full verbosity so the compiler
    # error is in this run's log instead of the next one.
    fails="$(grep -oE 'ERROR: [^ ]+ failed to build' "$LOG" | sed -E 's/^ERROR: //' | sort -u || true)"
    if [ -n "$fails" ]; then
        echo "== verbose re-run of the failing builddirs (V=sc) =="
        for p in $fails; do
            echo "-- $p: clean"
            make -j1 V=sc "$p/clean" 2>&1 | tee -a "$LOG" || true
            echo "-- $p: compile (real error follows)"
            make -j1 V=sc "$p/compile" 2>&1 | tee -a "$LOG" || true
        done
    else
        echo "no failing builddir named in the log; last 100 lines:" >&2
        tail -n 100 "$LOG" >&2 || true
    fi
    exit "$rc"
fi

echo "== images =="
find bin/targets/qualcommax/ipq807x -maxdepth 1 -name '*aw1000*sysupgrade*' -printf '%f  %s bytes\n'

# Name the release (BYTE 1.0.x) and write its notes. Nothing is uploaded.
if [[ -x "$PWD/../builder/local/stage-release.sh" ]]; then
    echo "== release =="
    "$PWD/../builder/local/stage-release.sh"
fi
