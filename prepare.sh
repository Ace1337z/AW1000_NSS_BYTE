#!/usr/bin/env bash
# Re-generate .config / feeds / overlays for the AW1000 NSS build (idempotent).
set -euo pipefail
cd "$(dirname "$0")"

# Layer this repo's builder overlay (devices/, local/, patches/) onto the
# upstream Qualcommax_NSS_Builder checkout. overlay/builder/ is the tracked
# source of truth; builder/ itself is a throw-away clone (git-ignored).
[ -d builder/.git ] || { echo "missing builder/ checkout - run ./ci/bootstrap.sh first" >&2; exit 1; }
cp -a overlay/builder/. builder/

# Substitute the release version from ./VERSION (single source of truth) into
# the staged config fragment before prepare-build.sh assembles .config, so
# /etc/openwrt_release and Status -> Overview carry "BYTE <version>".
VERSION_CUR="$(tr -d '[:space:]' < VERSION)"
sed -i "s/@VERSION@/$VERSION_CUR/g" builder/local/aw1000.fragment

# The Si32261 DSP patch is a vendor binary. It is stored base64 so the repo is
# pure text (reviewable diffs, no binary blob in git history); decode it into
# the overlay tree here. md5 3778fa32bf3a6e0ceab599778ed5149e.
FXS_DIR="$PWD/builder/devices/ipq807x-1g/files.ppe-nss/etc/fxs"
if [ ! -f "$FXS_DIR/si3226x_patch.bin" ]; then
	base64 -d "$FXS_DIR/si3226x_patch.bin.b64" >"$FXS_DIR/si3226x_patch.bin"
fi
chmod 644 "$FXS_DIR/si3226x_patch.bin"
# The base64 file is a transport detail for the repo, not image content: the
# copy under builder/ is what prepare-build.sh stages into openwrt/files, so
# drop it here or it ends up in the rootfs next to the decoded blob.
rm -f "$FXS_DIR/si3226x_patch.bin.b64"

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

# Apply patches to the src-link feeds (local-feeds/aw1000). Unlike the feeds
# under openwrt/feeds/ (handled inside prepare-build.sh), these are symlink
# farms into the bootstrap-pinned src/ checkouts, and GNU patch refuses to
# write through symlinked directories. Each patch is therefore a git diff
# against the src checkout repo root (src/<repo>/<path>) and is applied with
# git apply (idempotent: a reverse --check means it is already applied).
PATCH_LOCAL_FEEDS="$PWD/overlay/builder/patches/local-feeds/aw1000"
shopt -s nullglob
# Candidate repos are the src/ checkouts the aw1000 feed actually links to.
# Restricting to those keeps the search unambiguous: a patch header alone
# cannot name its repo (it may touch several files), and an unlinked checkout
# can hold an identical copy (e.g. src/passwall-pkgs duplicates the passwall
# Makefile that src/aw1000_byte ships), which would let a patch "already
# applied" match the wrong tree.
CANDIDATE_REPOS=""
for link in "$PWD"/local-feeds/aw1000/*; do
	real="$(readlink -f "$link")"
	case "$real" in
	"$PWD/src/"*)
		repo="${real#"$PWD/src/"}"
		repo="${repo%%/*}"
		[ -d "$PWD/src/$repo/.git" ] || continue
		case " $CANDIDATE_REPOS " in *" $repo "*) continue ;; esac
		CANDIDATE_REPOS="$CANDIDATE_REPOS $repo"
		;;
	esac
done
[ -n "${CANDIDATE_REPOS# }" ] || { echo "no src/ checkouts linked from local-feeds/aw1000" >&2; exit 1; }
for p in "$PATCH_LOCAL_FEEDS"/*.patch; do
	name="$(basename "$p")"
	matched=0
	for repo in $CANDIDATE_REPOS; do
		if git -C "$PWD/src/$repo" apply --check -R "$p" 2>/dev/null; then
			echo "[prepare] skipping $name (already applied in src/$repo)"
			matched=1
			break
		fi
		if git -C "$PWD/src/$repo" apply --check "$p" 2>/dev/null; then
			echo "[prepare] applying $name to src/$repo"
			git -C "$PWD/src/$repo" apply "$p" || {
				echo "local-feed patch $name failed to apply to src/$repo" >&2
				exit 1
			}
			matched=1
			break
		fi
	done
	[ "$matched" = 1 ] || {
		echo "local-feed patch $name applies to no linked src/ checkout (stale against pin):$CANDIDATE_REPOS" >&2
		exit 1
	}
done
shopt -u nullglob

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

# openwrt/files/ is a persistent staging dir: prepare-build.sh copies into it
# but never prunes, so a file removed from the overlay survives there and ships
# in the next image. Drop repo-transport leftovers after every prepare.
find openwrt/files -type f \( -name '*.b64' -o -name '*.orig' -o -name '*.rej' \) -delete 2>/dev/null || true
if [ -f openwrt/files/etc/fxs/si3226x_patch.bin.b64 ]; then
	echo "b64 blob still staged in openwrt/files" >&2
	exit 1
fi
