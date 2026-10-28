#!/usr/bin/env bash
#
# Build the AW1000 image natively, on a GitHub runner or on a workstation.
#
#   build/build.sh              fetch trees, prepare, build
#   build/build.sh prepare      fetch trees and prepare, stop before make
#   build/build.sh shell        interactive shell with the trees prepared
#   build/build.sh make ...     run make in the prepared tree
#   build/build.sh clean        remove the work directory
#
# Everything lives under $WORK (default: <repo>/work), so a build never touches
# anything outside this checkout. The pinned revisions are in build/versions.
#
# The image is APK based (CONFIG_USE_APK=y): packages come out as .apk and the
# on-device package index is packages.adb.

set -euo pipefail

REPO="$(cd -- "$(dirname -- "$0")/.." && pwd)"
WORK="${WORK:-$REPO/work}"
export WORK
export REPO

# shellcheck source=versions
. "$REPO/build/versions"

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

fetch() {
	# fetch <dir> <url> <sha> [sparse paths...]
	local dir="$1" url="$2" sha="$3"
	shift 3
	if [[ -d "$WORK/$dir/.git" ]] && git -C "$WORK/$dir" cat-file -e "$sha^{commit}" 2>/dev/null; then
		if [[ "$(git -C "$WORK/$dir" rev-parse HEAD)" = "$sha" ]]; then
			echo "  $dir: already at ${sha:0:12}"
			return 0
		fi
		log "checkout $dir ${sha:0:12}"
		git -C "$WORK/$dir" checkout -q --detach "$sha"
		return 0
	fi
	log "clone $dir ${sha:0:12}"
	# Keep a cached dl/ or .ccache/ (CI restores them before this script
	# runs): they live inside the tree directory, which we are about to
	# replace, so move them out and back.
	local keep=""
	for sub in dl .ccache; do
		if [[ -d "$WORK/$dir/$sub" ]]; then
			rm -rf "$WORK/.keep-$dir-$sub"
			mv "$WORK/$dir/$sub" "$WORK/.keep-$dir-$sub"
			keep="$keep $sub"
		fi
	done
	rm -rf "$WORK/$dir"
	mkdir -p "$WORK"
	git clone -q --filter=blob:none --no-checkout "$url" "$WORK/$dir"
	git -C "$WORK/$dir" checkout -q --detach "$sha"
	for sub in $keep; do
		mv "$WORK/.keep-$dir-$sub" "$WORK/$dir/$sub"
	done
	# Drop the origin remote: a later `feeds update` must not move the tree.
	git -C "$WORK/$dir" remote remove origin 2>/dev/null || true
}

fetch openwrt        "$OPENWRT_URL"        "$OPENWRT_SHA"
fetch nss-packages   "$NSS_PACKAGES_URL"   "$NSS_PACKAGES_SHA"
fetch builder-reference "$BUILDER_URL"     "$BUILDER_SHA"

# The feed points at this checkout through @WORK@, substituted by inside.sh.
ln -sfn "$REPO" "$WORK/aw1000-feed"

case "${1:-all}" in
clean)
	rm -rf "$WORK"
	echo "removed $WORK"
	;;
shell)
	exec bash -i
	;;
make)
	shift
	cd "$WORK/openwrt"
	exec make "$@"
	;;
prepare | all)
	exec "$REPO/build/inside.sh" "$1"
	;;
*)
	echo "usage: $0 [all|prepare|shell|make ...|clean]" >&2
	exit 1
	;;
esac
