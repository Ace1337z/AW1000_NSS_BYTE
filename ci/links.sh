#!/usr/bin/env bash
# Recreate the local-feeds/aw1000 links into src/. Idempotent.
#
# They are links rather than copies so a feed package is built from the exact
# commit ci/bootstrap.sh pinned: editing src/<repo>/ changes the image, with no
# second copy to drift. The links are not stored in git (the API cannot create
# symlinks), so both bootstrap and prepare call this.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/local-feeds/aw1000"

link() { # target name
	target=$1
	name=$2
	[ -e "$target" ] || { echo "missing source $target - run ./ci/bootstrap.sh" >&2; exit 1; }
	if [ -L "$name" ] && [ "$(readlink "$name")" = "$target" ]; then
		return 0
	fi
	[ ! -e "$name" ] || { echo "$name exists and is not the expected link" >&2; exit 1; }
	ln -s "$target" "$name"
}

link ../../src/aw1000_phone/openwrt/aw1000-fxs  aw1000-fxs
link ../../src/aw1000_phone/openwrt/fxsd        fxsd
link ../../src/aw1000_phone/openwrt/luci-app-fxs luci-app-fxs
link ../../src/passwall-pkgs2/chinadns-ng        chinadns-ng
link ../../src/passwall-pkgs2/geoview            geoview
link ../../src/passwall-pkgs2/tcping             tcping
link ../../src/aw1000_byte/packages/luci-app-modeminfo luci-app-modeminfo
link ../../src/aw1000_byte/packages/luci-app-passwall  luci-app-passwall
link ../../src/dotycat/luci-app-netstat          luci-app-netstat
link ../../src/dotycat/luci-app-aw1k-led        luci-app-aw1k-led
