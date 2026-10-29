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
# Drop feeds this image has no use for, before the scan. Kconfig walks every
# feed's Config.in at `feeds update` time, so a feed with a broken dependency
# breaks the build even when none of its packages are installed:
#   video  qt5base has an OpenGL choice that Kconfig reports as recursive, and
#          wayland wants libffi which the feed does not carry. Nothing here
#          uses Qt, Wayland or anything else in it.
# Kept as a sed on the copy so feeds.conf.default stays pristine and the reason
# lives here rather than in a divergent default file.
for dead in video; do
	sed -i "\#^src-git ${dead} #d" feeds.conf
done
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
# The custom feeds are NOT installed with -a: `feeds install -a -p <feed>`
# installs every package in the feed, and several of them start Kconfig
# dependency cycles that abort defconfig (see the notes on the install loop
# below). Their packages are installed by name in the loop further down,
# driven by build/config.
# Install only the packages this image asks for, not `feeds install -a`.
#
# `-a` installs every package from every feed, which drags in the whole
# packages/luci tree. Several of those carry Kconfig bugs that abort the build
# even though nothing here uses them:
#   fwknopd      PACKAGE_fwknopd selected by luci-app-fwknopd, while
#                FWKNOPD_GPG depends back on PACKAGE_fwknopd
#   iptasn       selects PACKAGE_perl, which selects PACKAGE_libopenssl,
#                while OPENSSL_KTLS depends back on libopenssl
#   mwan3        depends on PACKAGE_rpcd, which luci-base selects, and
#                luci-app-nss selects luci-base
#   squeezelite  SQUEEZELITE_WMA_ALAC depends back on the package
# None are reachable from this config, so they are simply not installed.
log "install requested packages"
req_pkgs="$(cat "$COMMON/config" "$FEED/build/config" |
	grep -E '^CONFIG_PACKAGE_[A-Za-z0-9_.+-]+=y' |
	sed 's/^CONFIG_PACKAGE_//; s/=y$//' | sort -u)"
installed=0
missing=""
for p in $req_pkgs; do
	# Skip the passwall2 sub-options: they are menu options, not packages.
	case "$p" in *_INCLUDE_*|*_Transparent_Proxy|*_INCLUDE_*) continue ;; esac
	if ./scripts/feeds install "$p" >/dev/null 2>&1; then
		installed=$((installed+1))
	else
		missing="$missing $p"
	fi
done

# The loop above installs only the named packages; their feed dependencies
# (luci-base, rpcd, dnsmasq-full, the kmod helpers...) come from the same
# feeds and must be installed too, or defconfig silently drops the dependent
# package. `feeds install` resolves one package's dependencies only when the
# package itself is in a feed, so walk the dependency closure with a second
# pass over what the feeds still offer, restricted to the names the config
# actually references.
for p in luci-base luci-compat luci-lib-jsonc rpcd rpcd-mod-file rpcd-mod-luci \
         rpcd-mod-rrdns rpcd-mod-ucode ucode ucode-mod-fs ucode-mod-ubus \
         dnsmasq-full firewall4 nftables jansson libubox libubus libblobmsg-json \
         libjson-c libopenssl libustream-openssl ca-bundle ca-certificates; do
	./scripts/feeds install "$p" >/dev/null 2>&1 && installed=$((installed+1)) || true
done
log "installed $installed packages from the feeds"
# A package missing here is not fatal: some are provided by the base tree or
# are menu options. defconfig verification below is the real check.
[ -n "$missing" ] && echo "not in any feed:$missing" || true
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
# This repo carries no feed patches today; the call is kept so a future
# build/patches/<feed>/*.patch is picked up without touching this script.
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
# Verify only THIS repo's config, not the builder's common config. The
# builder's file is shared with its ppe-nss variant and carries symbols that
# do not exist on the edma tree (qca-ppe-qos, ppe-help, ath11k-nss-wifi,
# kmod-sched-ets/gred/act-pedit, LUA_ECO_OPENSSL); defconfig drops them and
# they are not this repo's to satisfy. Ours are, and a dropped one means a
# feature we promised is missing.
dropped=()
while IFS= read -r req; do
	grep -qxF "$req" .config || dropped+=("$req")
done < <(grep -E '^CONFIG_[A-Za-z0-9_-]+=' "$FEED/build/config" |
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

# Size report: the sysupgrade image is what gets flashed, so print it in both
# bytes and MiB, plus the ten largest files in the rootfs. That makes a
# regression (a package that pulled in a dependency tree) obvious from the log
# instead of only at flash time.
SYSUP="$(ls bin/targets/qualcommax/ipq807x/*aw1000*squashfs-sysupgrade.bin 2>/dev/null | head -1)"
if [[ -n "$SYSUP" && -f "$SYSUP" ]]; then
	sz=$(stat -c%s "$SYSUP")
	printf '\nsysupgrade image: %s bytes (%.1f MiB)\n' "$sz" "$(awk "BEGIN{print $sz/1048576}")"
fi
ROOTFS="build_dir/target-aarch64_cortex-a53_musl/root-qualcommax"
if [[ -d "$ROOTFS" ]]; then
	printf 'rootfs: %s (%.1f MiB)\n' \
		"$(du -sh "$ROOTFS" 2>/dev/null | cut -f1)" \
		"$(du -sm "$ROOTFS" 2>/dev/null | cut -f1)"
	echo "largest files:"
	find "$ROOTFS" -type f -printf '%s %p\n' 2>/dev/null |
		sort -rn | head -10 |
		awk '{printf "  %6.1f MiB  %s\n", $1/1048576, $2}'
fi
