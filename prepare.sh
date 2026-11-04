#!/usr/bin/env bash
# Re-generate .config / feeds / overlays for the AW1000 NSS build (idempotent).
set -euo pipefail
cd "$(dirname "$0")"

# Layer this repo's builder overlay (devices/, local/, patches/) onto the
# upstream Qualcommax_NSS_Builder checkout. overlay/builder/ is the tracked
# source of truth; builder/ itself is a throw-away clone (git-ignored).
[ -d builder/.git ] || { echo "missing builder/ checkout - run ./ci/bootstrap.sh first" >&2; exit 1; }
cp -a overlay/builder/. builder/

# The Si32261 DSP patch is a vendor binary. It is stored base64 so the repo is
# pure text (reviewable diffs, no binary blob in git history); decode it into
# the overlay tree here. md5 3778fa32bf3a6e0ceab599778ed5149e.
FXS_DIR="$PWD/builder/devices/ipq807x-1g/files.ppe-nss/etc/fxs"
if [ ! -f "$FXS_DIR/si3226x_patch.bin" ]; then
	base64 -d "$FXS_DIR/si3226x_patch.bin.b64" >"$FXS_DIR/si3226x_patch.bin"
fi
chmod 644 "$FXS_DIR/si3226x_patch.bin"

# Executable bits do not survive every transport (GitHub's contents API commits
# everything as 100644), and OpenWrt copies these files into the image as-is: a
# 0644 init script or uci-defaults file silently does nothing.
find builder/devices -type f \
	\( -path '*/etc/init.d/*' -o -path '*/etc/uci-defaults/*' \
	   -o -path '*/etc/hotplug.d/*' -o -path '*/etc/board.d/*' \
	   -o -path '*/usr/sbin/*' \) -exec chmod 755 {} +
chmod 755 prepare.sh build.sh ci/*.sh builder/local/stage-release.sh

# local-feeds/aw1000 links into the bootstrap-pinned src/ checkouts.
./ci/links.sh

OPENWRT_DIR="$PWD/openwrt" \
BUILDER_REPO="$PWD/builder" \
VARIANT=ppe-nss \
DEVICE=ipq807x-1g \
COMMON=common \
CONFIG_FRAGMENT=local/aw1000.fragment \
FEEDS="src-git nss https://github.com/JuliusBairaktaris/nss-packages.git;ppe-nss
src-git luci https://github.com/JuliusBairaktaris/luci.git;luci-app-ppe-qos
src-git qmodem https://github.com/FUjr/QModem.git^b4effcdaa7f73b26b27f01a8cca3c31f8e98be26
src-link aw1000 $PWD/local-feeds/aw1000" \
bash builder/scripts/prepare-build.sh
