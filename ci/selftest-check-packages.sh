#!/usr/bin/env bash
# Self-test for ci/check-packages.py.
#
# The checker is the only gate that catches "apk rejects this at the very end of
# a 3 h image build". A silent regression in it (a relaxed version regex, a
# collision map that stops recording, an unreadable index) would put the build
# back to failing after hours, so preflight runs this tiny fixture-based test
# against synthetic package metadata: a clean tree must pass, and a tree with an
# opkg-style version plus two packages owning one file must report exactly both.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$ROOT/ci/check-packages.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fails=0

mk_tree() { # dir
	local d=$1
	mkdir -p "$d/openwrt/tmp" "$d/openwrt/package/a/files/etc/config" \
		"$d/openwrt/package/b/files/etc/config"
	cat >"$d/openwrt/package/a/Makefile" <<'EOF'
include $(TOPDIR)/rules.mk
PKG_NAME:=pkg-a
PKG_VERSION:=1.0
PKG_RELEASE:=1
include $(INCLUDE_DIR)/package.mk
define Package/pkg-a/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/shared $(1)/etc/config/
endef
$(eval $(call BuildPackage,pkg-a))
EOF
	cat >"$d/openwrt/package/b/Makefile" <<'EOF'
include $(TOPDIR)/rules.mk
PKG_NAME:=pkg-b
PKG_VERSION:=2.0
PKG_RELEASE:=1
include $(INCLUDE_DIR)/package.mk
define Package/pkg-b/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/shared $(1)/etc/config/
endef
$(eval $(call BuildPackage,pkg-b))
EOF
	touch "$d/openwrt/package/a/files/etc/config/shared" \
		"$d/openwrt/package/b/files/etc/config/shared"
}

mk_info() { # dir version-b
	cat >"$1/openwrt/tmp/.packageinfo" <<EOF
Source-Makefile: package/a/Makefile

Package: pkg-a
Version: 1.0-r1
Section: utils
@@

Source-Makefile: package/b/Makefile

Package: pkg-b
Version: $2
Section: utils
@@
EOF
	printf 'CONFIG_PACKAGE_pkg-a=y\nCONFIG_PACKAGE_pkg-b=y\n' >"$1/openwrt/.config"
}

# 1. Clean metadata: shared directories and distinct files are fine.
GOOD="$TMP/good"
mk_tree "$GOOD"
sed -i 's#files/etc/config/shared#files/etc/config/other#' "$GOOD/openwrt/package/b/Makefile"
touch "$GOOD/openwrt/package/b/files/etc/config/other"
rm -f "$GOOD/openwrt/package/b/files/etc/config/shared"
mk_info "$GOOD" "2.0-r1"
if out="$(python3 "$CHECK" "$GOOD" 2>&1)"; then
	if grep -q "no ownership collisions" <<<"$out"; then
		echo "  ok    self-test: clean metadata passes"
	else
		echo "  FAIL  self-test: clean metadata passed without a summary: $out"
		fails=$((fails + 1))
	fi
else
	echo "  FAIL  self-test: clean metadata rejected: $out"
	fails=$((fails + 1))
fi

# 2. Two packages installing the same file must be reported.
BAD="$TMP/bad"
mk_tree "$BAD"
mk_info "$BAD" "2.0-r1"
if out="$(python3 "$CHECK" "$BAD" 2>&1)"; then
	echo "  FAIL  self-test: file collision not detected"
	fails=$((fails + 1))
elif grep -q "FAIL: file collision: /etc/config/shared owned by pkg-a, pkg-b" <<<"$out"; then
	echo "  ok    self-test: file collision detected"
else
	echo "  FAIL  self-test: collision detected but not reported as expected: $out"
	fails=$((fails + 1))
fi

# 3. opkg-style <ver>-<n> must be rejected, <ver>-r<n> accepted.
BADVER="$TMP/badver"
mk_tree "$BADVER"
mk_info "$BADVER" "2.0-7"
if out="$(python3 "$CHECK" "$BADVER" 2>&1)"; then
	echo "  FAIL  self-test: '2.0-7' accepted (apk would reject it)"
	fails=$((fails + 1))
elif grep -q "FAIL: pkg-b: version '2.0-7' is invalid for apk" <<<"$out"; then
	echo "  ok    self-test: opkg-style version rejected"
else
	echo "  FAIL  self-test: wrong version diagnostic: $out"
	fails=$((fails + 1))
fi

exit "$fails"
