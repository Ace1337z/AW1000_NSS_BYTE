#!/usr/bin/env bash
# Stage the built images as a named release: BYTE <version>.
#
#   ./builder/local/stage-release.sh            # stage + write notes
#   ./builder/local/stage-release.sh --publish  # also create the GitHub release
#
# Version comes from ./VERSION (1.0.x, first release 1.0.1). Release name is
# "BYTE <version>", tag is "BYTE-<version>". Notes describe this build: the
# pinned sources, the package versions in the config, the features the image
# carries and the flashing/recovery rules. Nothing is uploaded unless
# --publish is given.
set -euo pipefail
ROOT="$(cd "$(dirname -- "$0")/../.." && pwd)"
OPENWRT="$ROOT/openwrt"
VERSION_FILE="$ROOT/VERSION"
TARGET_DIR="$OPENWRT/bin/targets/qualcommax/ipq807x"

[[ -f "$VERSION_FILE" ]] || { echo "missing $VERSION_FILE" >&2; exit 1; }
VERSION="$(tr -d '[:space:]' <"$VERSION_FILE")"
[[ "$VERSION" =~ ^1\.0\.[0-9]+$ ]] || {
	echo "VERSION must be 1.0.x (first release 1.0.1), got '$VERSION'" >&2
	exit 1
}
TAG="BYTE-$VERSION"
NAME="BYTE $VERSION"
OUT="$ROOT/releases/$TAG"

shopt -s nullglob
images=("$TARGET_DIR"/*arcadyan_aw1000*squashfs-sysupgrade.bin)
((${#images[@]})) || {
	echo "no aw1000 sysupgrade image in $TARGET_DIR - run ./build.sh first" >&2
	exit 1
}

pkgver() {
	awk -v p="$1" '/^Package:/{q=substr($0,10)} q==p && /^Version:/{print substr($0,10); exit}' \
		"$OPENWRT/tmp/.packageinfo" 2>/dev/null
}

kver() {
	awk '/^LINUX_VERSION-[0-9]/{print $1; exit}' \
		"$OPENWRT/include/kernel-version.mk" 2>/dev/null |
		sed 's/^LINUX_VERSION-//;s/=$//'
}

git_pin() {
	git -C "$1" describe --always --dirty --tags 2>/dev/null ||
		git -C "$1" rev-parse --short HEAD 2>/dev/null || echo unknown
}

mkdir -p "$OUT"
rm -f "$OUT"/BYTE-*.bin "$OUT"/sha256sums "$OUT/RELEASE.md"

staged=()
for img in "${images[@]}"; do
	dst="$OUT/$TAG-arcadyan_aw1000-squashfs-sysupgrade.bin"
	cp -f "$img" "$dst"
	staged+=("$dst")
done
(cd "$OUT" && sha256sum BYTE-*.bin >sha256sums)

{
	cat <<EOF
# $NAME

OpenWrt ppe-nss (NSS offload) for the Arcadyan AW1000, built from this tree.

- release: \`$TAG\` (name \`$NAME\`)
- built: $(date -u '+%Y-%m-%d %H:%M UTC')
- kernel: $(kver)
- NSS firmware: 12.5 (11.4 shipped too, mesh only)
- OpenWrt tree: $(git_pin "$OPENWRT")
- builder: $(git_pin "$ROOT/builder")

## Package versions

| package | version |
| --- | --- |
| luci-app-passwall2 | $(pkgver luci-app-passwall2) |
| xray-core | $(pkgver xray-core) |
| luci-app-modeminfo | $(pkgver luci-app-modeminfo) |
| luci-app-byte | $(pkgver luci-app-byte) |
| luci-app-fxs | $(pkgver luci-app-fxs) |
| luci-theme-footstrap | $(pkgver luci-theme-footstrap) |
| qmodem | $(pkgver qmodem) |
| aw1000-dashboard | $(pkgver aw1000-dashboard) |

## What is in this build

- NSS offload pinned on: \`nss-wifi.general.offload=1\`, fw4 flow offloading
  (software + hardware) and the flow-table include are re-asserted every boot
  by \`/etc/init.d/aw1000-nss\` before the radios probe. Wired traffic uses the
  PPE, Wi-Fi uses the NSS cores.
- Wi-Fi: SSID \`BYTE\`, 2.4 + 5 GHz, open, country \`US\`.
- Login: \`root\` with no password, SSH and LuCI included (change it).
- Hostname \`BYTE\`, description \`BYTE by ACE\`, BYTE login banner.
- LuCI theme: **Footstrap is the default** (\`luci.main.mediaurlbase\` set at
  first boot by \`/etc/uci-defaults/93-aw1000-theme\`); Bootstrap stays
  installed as a fallback.
- Dashboard: mobile, thermal and storage cards; the NSS card is replaced by
  Storage; the bottom detail tabs and the layout editor are hidden.
- BYTE panel under **Tools**: AdGuard Home setup/status (with dry-run and
  undo/uninstall), DNS chain, system state; PassWall2 nodes live under Services.
- PassWall v1 (4.66-8) and PassWall2 (Xray only, VLESS) - no geodata packages;
  install \`v2ray-geoip\`/\`v2ray-geosite\`/geoview only if geo rules are wanted.
- OpenClash and Nikki dependencies only (bash, ruby, yq, kmod-inet-diag,
  kmod-dummy, nft tproxy/socket, dnsmasq-full nftset, ...). Neither app nor
  its core is installed; install them later from their feed.
- Tuning: BBR + fq + TCP Fast Open, \`tcp_slow_start_after_idle=0\`,
  \`netdev_max_backlog=16384\`, \`netdev_budget=2400\`, performance governor,
  modem IRQs spread over the secondary CPUs, 512 MB zstd zram swap.
- QModem with the TTL chain on \`wwan0_1\`; its uplink manager no longer
  disables flow offloading. Offloaded flows still bypass TTL rewrite.
- Modem uplink MTU 1420 on every redial (UCI, the managed-IPv4 event and a
  hotplug re-pin). QModem no longer leaves \`network.<if>\`/\`<if>v6\` deleted
  after a hang: the dial path recreates them.
- RJ11 phone: the Skyworks Si32261 DSP patch ships in \`/etc/fxs\`; fxsd checks
  PCM and forces the modem to slave. LAN SIP (QModem voice/SIM) is enabled by
  default with fixed universal credentials (to \`qmodem\` / \`QModem!VOIP-
  2026-x9Kt7Wp4\`, UCI \`/etc/config/qmodem_sip\` mode 0600, QR in release
  notes). The experimental call service and its HTTPS/WebSocket media access
  are enabled by default too (UCI \`qmodem_voip.main.enabled\` /
  \`web_enabled\` = 1). Dial tone, ringing, DTMF, caller ID, hold, speed dial,
  blocked numbers, call history available.
- IPv6 detected at boot: \`wan6\` DHCPv6 + \`ip6assign\` on LAN; while no usable
  v6 exists, dnsmasq \`filter_AAAA\` keeps clients on IPv4.
- vnstat database in \`/etc/vnstat\` (SQLite, one \`vnstat.db\`); its LuCI
  menu node is hidden, and the NetStat graph now lists the real interfaces
  instead of \`vnstat.db\`.
- WebUI is served over plain HTTP only (\`http://192.168.1.1\`): uhttpd
  listens on port 80, HTTPS is off and there is no redirect. A LAN IP cannot
  have a warning-free HTTPS without the client importing a CA, so the UI is
  HTTP - the same trade the reference firmware makes, and no cert warning.
- Default network topology: the cellular modem (\`wwan0_1\`) is the WAN
  (\`wan\` DHCP + \`wanv6\` DHCPv6, metric 11) and the 2.5G ethernet jack is
  just another port in \`br-lan\` — same as the reference firmware, so the box
  is online out of the box with no ethernet WAN to configure.
- Wi-Fi defaults now use 5G channel 149 (UNII-3, DFS-free) to match the
  reference firmware; 2.4 GHz stays on channel 1.
- CPU usage spread across all four cores by two services: \`smp-affinity\`
  pins the ath11k Wi-Fi rings and edma LAN/WAN interrupts one per core, and
  \`aw1000-affinity\` spreads the modem packet path via RPS/XPS/RFS (re-applied
  on every redial). \`aw1000-tuning\` now just pins the CPU at 2.2 GHz
  performance.
- First-boot Wi-Fi: the ath11k phys are loaded by \`/etc/init.d/nss-wifi\`,
  not the boot-time kmodloader, so netifd could start before any radio was
  known and leave the box without an SSID. The image now ships a default
  \`/etc/config/wireless\` (radio0 5G, radio1 2G, open \`BYTE\`), so netifd
  always has a device to start. \`/etc/init.d/aw1000-wifi-ensure\` is enabled
  and, if a hotplug ever loses the race, regenerates an empty config and
  reloads netifd once; a second reload is bounded. Details in
  \`/tmp/log/aw1000-wifi-ensure.log\`.

## Install

Sysupgrade image only, no factory image. The device must already run OpenWrt
or be recovered to it over serial/TFTP first.

    sysupgrade -n $TAG-arcadyan_aw1000-squashfs-sysupgrade.bin

\`-n\` discards settings and is required for the first flash. Keep a serial
console or the vendor TFTP recovery path reachable, and a known-good image
plus config backup, before flashing.

## Checksums

$(cat "$OUT/sha256sums")
EOF
} >"$OUT/RELEASE.md"

echo "staged $NAME in $OUT"
echo "  $(basename "${staged[0]}")"
echo "  release notes: $OUT/RELEASE.md"

if [[ "${1:-}" == "--publish" ]]; then
	gh release create "$TAG" "${staged[@]}" "$OUT/sha256sums" \
		--title "$NAME" --notes-file "$OUT/RELEASE.md" \
		--repo "$(gh repo view --json nameWithOwner -q .nameWithOwner)"
	echo "published $NAME ($TAG)"
fi
