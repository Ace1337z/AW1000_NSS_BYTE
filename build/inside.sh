#!/usr/bin/env bash
#
# Prepare and build the AW1000 image. Runs from build/build.sh, after the
# pinned trees are in $WORK:
#
#   $WORK/openwrt             build tree (read-write)
#   $WORK/nss-packages        NSS feed (read-write: package patches are copied in)
#   $WORK/builder-reference   common NSS config + overlays
#   $WORK/aw1000-feed         symlink to this repo
#
# Order matters and mirrors Qualcommax_NSS_Builder's scripts/prepare-build.sh,
# narrowed to a single AW1000 profile:
#   1. feeds.conf = default + build/feeds, custom feeds installed first
#   2. feed patches, then tree patches, then extra NSS package patches
#   3. .config = builder common config + build/config, verified after defconfig
#   4. overlay files from the builder and from this repo
#   5. download, build

set -euo pipefail

STEP="${1:-all}"
FEED="$WORK/aw1000-feed"
BUILDER="$WORK/builder-reference"
COMMON="$BUILDER/devices/common"
cd "$WORK/openwrt"

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 1. feeds
log "feeds.conf"
cp feeds.conf.default feeds.conf
# @WORK@ keeps build/feeds free of absolute paths, so the same file works on a
# runner (where $WORK is under the checkout) and on a workstation.
sed "s|@WORK@|$WORK|g" "$FEED/build/feeds" | grep -vE '^\s*(#|$)' >>feeds.conf
cat feeds.conf
# scan.mk caches each feed's Makefile list under the scanner's PID, which is
# the same in every fresh container, so new packages in a src-link feed would
# never be indexed. Drop the cached lists to force a rescan.
rm -f feeds/*.tmp/info/.files-*
./scripts/feeds update -a
# Start from no installed feed packages, so a feed dropped from build/feeds
# leaves nothing behind in package/feeds.
rm -rf package/feeds
custom="$(grep -vE '^\s*(#|$)' "$FEED/build/feeds" | awk '{print $2}')"
for pref in $(grep -vE '^\s*(#|$)' "$FEED/build/feeds.prefer"); do
	log "install ${pref#*/} from ${pref%%/*}"
	./scripts/feeds install -p "${pref%%/*}" "${pref#*/}"
done
for f in $custom; do
	log "install feed $f"
	./scripts/feeds install -a -p "$f"
done
log "install remaining feeds"
./scripts/feeds install -a
for pkg in $(grep -vE '^\s*(#|$)' "$FEED/build/feeds.exclude"); do
	log "exclude $pkg"
	rm -f "package/feeds/$pkg"
done

# -------------------------------------------------------------- 2. patches
# <dir>/<feed>/*.patch, paths relative to the feed root.
apply_patches() {
	local p feed
	shopt -s nullglob
	for p in "$1"/*/*.patch; do
		feed="feeds/$(basename "$(dirname "$p")")"
		if patch -p1 -d "$feed" --dry-run --forward <"$p" >/dev/null 2>&1; then
			log "patch $feed: $(basename "$p")"
			patch -p1 -d "$feed" --forward <"$p"
		elif patch -p1 -d "$feed" --dry-run --reverse <"$p" >/dev/null 2>&1; then
			echo "already applied: $(basename "$p")"
		else
			die "does not apply to $feed: $p"
		fi
	done
	shopt -u nullglob
}
apply_patches "$BUILDER/patches/feeds/ppe-nss"
apply_patches "$FEED/build/patches"

# Patches to the OpenWrt tree itself (build/patches-openwrt/*.patch, -p1).
for p in "$FEED"/build/patches-openwrt/*.patch; do
	[[ -e "$p" ]] || continue
	if patch -p1 --dry-run --forward <"$p" >/dev/null 2>&1; then
		log "patch openwrt: $(basename "$p")"
		patch -p1 --forward <"$p"
	elif patch -p1 --dry-run --reverse <"$p" >/dev/null 2>&1; then
		echo "already applied: $(basename "$p")"
	else
		die "does not apply to openwrt: $p"
	fi
done

# --------------------------------------------------------------- 3. config
log ".config"
configs=("$COMMON/config" "$FEED/build/config")
cat "${configs[@]}" >.config
make defconfig

# Anything requested =y that defconfig dropped is a broken image, not a
# warning: a typo in a package name is otherwise invisible until the router is
# flashed and the feature is missing.
dropped=()
while IFS= read -r req; do
	grep -qxF "$req" .config || dropped+=("$req")
done < <(cat "${configs[@]}" |
	grep -E '^CONFIG_[A-Za-z0-9_-]+=' |
	awk -F= '{ last[$1] = $0 } END { for (s in last) print last[s] }' |
	grep -vE '=n$')
if ((${#dropped[@]})); then
	echo "defconfig dropped requested symbols:" >&2
	printf '  %s\n' "${dropped[@]}" >&2
	die "config verification failed"
fi

# Requested off: fail if something pulled them back in. uqmi and the upstream
# qmi_wwan claim the same Quectel IDs as qmi_wwan_q, so both drivers bound to
# one modem is a coin flip at boot.
for sym in CONFIG_PACKAGE_uqmi CONFIG_PACKAGE_kmod-usb-net-qmi-wwan; do
	if grep -qE "^${sym}=[ym]" .config; then
		die "$sym came back on; something depends on it (see build/patches-openwrt/0003)"
	fi
done

# APK, not OPKG. The tree defaults to APK; this catches a rebase that flips it.
grep -qE '^CONFIG_USE_APK=y' .config || die "USE_APK is off: image would ship ipkg"

# Custom feeds are not offered as package repositories on the router: they are
# built into the image, and their packages are unsigned.
for f in $custom; do
	sed -i "s/^CONFIG_FEED_${f}=.*/# CONFIG_FEED_${f} is not set/" .config
done

# -------------------------------------------------------------- 4. overlay
log "overlay files"
rm -rf files
mkdir -p files
for src in "$COMMON/files" "$COMMON/files.ppe-nss"; do
	[[ -d "$src" ]] && cp -a "$src/." files/
done
# This repo's own overlay last, so it wins.
[[ -d "$FEED/files" ]] && cp -a "$FEED/files/." files/
# The BYTE runtime: init scripts, tuning, config and helpers.
cp -a "$FEED/byte/files/." files/

# sshd_config.d/10-root-login.conf already allows root with an empty password,
# like stock OpenWrt's dropbear: a fresh install is reachable, and the firewall
# drops WAN input.
if [[ -f files/etc/ssh/sshd_config ]]; then
	sed -i '/^#\?PermitEmptyPasswords/d' files/etc/ssh/sshd_config
	sed -i '/^PasswordAuthentication/a PermitEmptyPasswords yes' files/etc/ssh/sshd_config
	chmod 0600 files/etc/ssh/sshd_config
fi

# Site-specific files (Wi-Fi keys, networks, SSH keys) from ../private-files,
# kept out of this repo. Never used by CI.
if [[ -d "$FEED/../private-files" ]]; then
	log "private overlay"
	cp -a "$FEED/../private-files/." files/
	rm -f files/.gitignore
	# cp -a also copies the private dir's own 0700 mode onto files/, which
	# becomes the image's / and stalls boot at ubusd (runs as non-root)
	find files -type d -exec chmod 0755 {} +
	[[ -d files/root/.ssh ]] && chmod 0700 files/root/.ssh
fi

[[ "$STEP" = prepare ]] && { log "prepared (make not run)"; exit 0; }

log "download"
make download -j8

log "build"
make -j"$(nproc)" || make -j1 V=s

log "images"
ls -l bin/targets/qualcommax/ipq807x/*aw1000* 2>/dev/null || true
