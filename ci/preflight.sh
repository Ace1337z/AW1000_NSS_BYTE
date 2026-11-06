#!/usr/bin/env bash
# Fast pre-flight for the AW1000 NSS build definition.
#
# Proves, in seconds and without compiling anything, that the pieces which
# normally only fail after hours of building are consistent:
#
#   - VERSION / required files / workflow YAML
#   - shell and JSON syntax of every overlay + feed script we ship
#   - the .config really kept every symbol the fragment asked for
#   - every builder patch is applied cleanly to the pinned feed
#   - the overlay and the decoded vendor blob actually reached openwrt/files
#     with the right mode, and nothing extra leaked in
#   - local-feeds symlinks resolve, no decoded blob is tracked in git
#
# Run it after ./prepare.sh. Exit code 1 on any FAIL. Warnings (a missing
# optional tool) never fail the run.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fails=0
warns=0
ok()   { printf '  ok    %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }
warn() { printf '  warn  %s\n' "$*"; warns=$((warns + 1)); }
head2() { printf '\n== %s ==\n' "$*"; }

OVERLAY_DEV="$ROOT/builder/devices/ipq807x-1g/files.ppe-nss"
STAGED="$ROOT/openwrt/files"
CONFIG="$ROOT/openwrt/.config"
PATCH_FEEDS="$ROOT/builder/patches/feeds"
VARIANT="ppe-nss" # variant id, matches files.<variant> and patches/feeds/<variant>
BLOB_MD5=3778fa32bf3a6e0ceab599778ed5149e

head2 "version and layout"
VERSION="$(tr -d '[:space:]' <"$ROOT/VERSION" 2>/dev/null || true)"
if [[ "$VERSION" =~ ^1\.0\.[0-9]+$ ]]; then
	ok "VERSION=$VERSION"
else
	bad "VERSION must match 1.0.x, got '$VERSION'"
fi
for f in prepare.sh build.sh ci/bootstrap.sh ci/links.sh overlay/builder/local/aw1000.fragment \
	overlay/builder/local/stage-release.sh .github/workflows/build.yml; do
	[ -e "$ROOT/$f" ] && ok "present $f" || bad "missing $f"
done
[ -d "$ROOT/openwrt" ] && [ -f "$CONFIG" ] || bad "openwrt/ not prepared - run ./prepare.sh first"
[ -d "$STAGED" ] || bad "openwrt/files/ not staged - run ./prepare.sh first"

head2 "workflow YAML"
if python3 -c 'import yaml' 2>/dev/null; then
	python3 - "$ROOT/.github/workflows/build.yml" <<'PY' || bad "workflow YAML does not parse"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
assert d["jobs"]["build"]["steps"], "no steps"
steps = [s.get("name", "?") for s in d["jobs"]["build"]["steps"]]
for want in ("Bootstrap pinned sources", "Prepare feeds, config and overlays", "Build image",
             "Verify image and release metadata", "Publish release"):
    assert want in steps, f"missing step: {want}"
PY
	ok "workflow parses, required steps present"
else
	warn "python3-yaml absent, workflow not parsed"
fi

head2 "shell syntax and build verbosity"
shell_n=0
while IFS= read -r f; do
	# Binary files (the decoded vendor blob lives in the tree) would trip the
	# null-byte guard on read; only real shebang files can be shell scripts.
	[ "$(head -c 2 "$f" 2>/dev/null)" = '#!' ] || continue
	shebang="$(head -1 "$f" 2>/dev/null)"
	case "$shebang" in
		*#!*bash*) interp=bash ;;
		*#!*/sh*|*#!*' sh'*) interp=sh ;;
		*) continue ;;
	esac
	shell_n=$((shell_n + 1))
	"$interp" -n "$f" 2>/dev/null || bad "$f fails $interp -n"
done < <(find "$ROOT/overlay" "$ROOT/local-feeds" "$ROOT/ci" "$ROOT/builder/local" \
		-type f ! -name '*.patch' ! -name '*.b64' 2>/dev/null | sort)
ok "$shell_n shell scripts parsed"
# include/verbose.mk drops every sub-make's stdout+stderr into /dev/null when
# the make invocation has no V= in it, which hides the compiler error behind
# "package/X failed to build". Both the world build and the verbose failure
# re-run must therefore pass an explicit V=.
grep -qE 'make -j"\$JOBS" V=s' "$ROOT/build.sh" &&
	ok "build.sh runs make with V=s" || bad "build.sh must pass V=s (silent make hides compiler errors)"
grep -qE 'make -j1 V=sc "\$p/compile"' "$ROOT/build.sh" &&
	ok "build.sh re-runs failing builddirs with V=sc" || bad "build.sh lost the verbose failure re-run"
grep -q 'Upload build log on failure' "$ROOT/.github/workflows/build.yml" &&
	ok "workflow keeps build.log on failure" || bad "workflow does not upload build.log on failure"
# The vendor modem modules are the only out-of-tree kernel modules in the tree
# and upstream CI never builds them: keep them in the fast smoke phase so a
# kernel API/modpost break costs ~1 h instead of a full world build.
for p in package/feeds/qmodem/quectel_MHI package/feeds/qmodem/quectel_QMI_WWAN \
	package/feeds/qmodem/simcom_QMI_WWAN package/feeds/aw1000/aw1000-fxs; do
	grep -q "$p/compile" "$ROOT/build.sh" &&
		ok "smoke builds $p" || bad "build.sh smoke list must include $p"
done

head2 "json syntax"
json_n=0
while IFS= read -r f; do
	json_n=$((json_n + 1))
	jq empty "$f" 2>/dev/null || bad "invalid JSON: ${f#"$ROOT/"}"
done < <(find "$ROOT/overlay" "$ROOT/local-feeds" -type f -name '*.json' 2>/dev/null | sort)
ok "$json_n JSON files parsed"

head2 "package makefiles"
pkg_n=0
while IFS= read -r f; do
	pkg_n=$((pkg_n + 1))
	grep -q 'include $(TOPDIR)/rules.mk' "$f" || bad "${f#"$ROOT/"}: no rules.mk include"
	if ! grep -qE 'BuildPackage|include .*luci\.mk' "$f"; then
		bad "${f#"$ROOT/"}: no BuildPackage/luci.mk"
	fi
done < <(find "$ROOT/local-feeds/aw1000" -maxdepth 2 -name Makefile 2>/dev/null | sort)
ok "$pkg_n vendored/local package makefiles differ"

head2 "config symbols"
if [ -f "$CONFIG" ]; then
	sym_n=0
	while IFS= read -r sym; do
		sym_n=$((sym_n + 1))
		grep -qx "$sym" "$CONFIG" || bad "$sym requested by fragment but not in .config"
	done < <(grep -E '^CONFIG_[A-Za-z0-9_]+=y$' "$ROOT/builder/local/aw1000.fragment" | sort -u)
	ok "$sym_n fragment symbols kept"
	for sym in CONFIG_PACKAGE_luci-theme-footstrap=y CONFIG_PACKAGE_luci-theme-bootstrap=y \
		CONFIG_PACKAGE_fxsd=y CONFIG_PACKAGE_luci-app-byte=y CONFIG_PACKAGE_luci-app-passwall2=y \
		CONFIG_PACKAGE_luci-app-passwall=y CONFIG_PACKAGE_xray-core=y CONFIG_PACKAGE_vnstat2=y \
		CONFIG_PACKAGE_luci-app-netstat=y CONFIG_PACKAGE_luci-app-modeminfo=y \
		CONFIG_PACKAGE_luci-app-qmodem=y CONFIG_PACKAGE_luci-app-qmodem-ttlfw4=y \
		CONFIG_PACKAGE_nss-firmware=y CONFIG_PACKAGE_kmod-nss-wifi-drv=y; do
		grep -qx "$sym" "$CONFIG" || bad "required symbol missing: $sym"
	done
	ok "required package set present"
	# A symbol that silently turned into =m still builds, but it does not ship.
	if grep -qE '^CONFIG_PACKAGE_luci-theme-footstrap=m$' "$CONFIG"; then
		bad "luci-theme-footstrap is =m, it would not be in the image"
	fi
	# CONFIG_ALL_KMODS=y makes the world build compile every kmod package in
	# every feed (~1100 modules); any legacy driver that does not track the
	# current kernel API then fails the build even though it is not in the
	# image. PF_RING 9.2.0 (kmod-pf-ring) is the known one on linux-6.18.
	# The image ships exactly the =y modules, so build only those.
	if grep -qE '^CONFIG_ALL_KMODS=y$' "$CONFIG"; then
		bad "CONFIG_ALL_KMODS=y would build all ~1100 kmods (PF_RING breaks on 6.18); the fragment must set it n"
	fi
	for sym in CONFIG_PACKAGE_kmod-pf-ring CONFIG_PACKAGE_libpfring; do
		if grep -qE "^$sym=[ym]$" "$CONFIG"; then
			bad "$sym must be off (PF_RING cannot build against linux-6.18)"
		fi
	done
fi

head2 "feed patches"
if [ -d "$PATCH_FEEDS" ]; then
	# Patches in one feed directory are applied in sort order and stack on top
	# of each other (0001 and 0002 both touch the luci-mod-dashboard index.js),
	# so they cannot be checked one by one against the prepared tree: after
	# prepare.sh every patch is applied, and after the second one the first
	# patch no longer reverses cleanly (its context now contains lines the next
	# patch added). Instead take a pristine copy of the pinned feed HEAD and
	# apply the whole group forward, exactly as builder/scripts/prepare-build.sh
	# does. Anything that fails means the pin moved under the patch.
	patch_n=0
	while IFS= read -r feed; do
		feed="${feed#*/}" # <variant>/<feed> -> <feed>
		readarray -t feed_patches < <(find "$PATCH_FEEDS/$VARIANT/$feed" -type f -name '*.patch' | sort)
		[ "${#feed_patches[@]}" -gt 0 ] || continue
		dir="$ROOT/openwrt/feeds/$feed"
		if [ ! -d "$dir/.git" ]; then
			bad "patch $feed: feeds/$feed is not a git checkout"
			continue
		fi
		tmp="$(mktemp -d "${TMPDIR:-/tmp}/feedcheck.XXXXXX")"
		git -C "$dir" archive HEAD | tar -xf - -C "$tmp"
		rc=0
		for p in "${feed_patches[@]}"; do
			patch -p1 -d "$tmp" --forward <"$p" >/dev/null 2>&1 || rc=1
		done
		rm -rf "$tmp"
		if [ "$rc" -ne 0 ]; then
			bad "$feed patches do not apply to the pinned feed HEAD (feed moved?):${feed_patches[*]}"
		fi
		patch_n=$((patch_n + ${#feed_patches[@]}))
	done < <(find "$PATCH_FEEDS" -mindepth 2 -maxdepth 2 -type d | sort | sed "s|$PATCH_FEEDS/||")
	ok "$patch_n builder patches verified against pinned feeds (pristine HEAD, cumulative per feed)"
fi

head2 "local-feed patches"
LPF="$ROOT/builder/patches/local-feeds"
if [ -d "$LPF" ]; then
	# Candidate repos: the src/ checkouts the aw1000 feed links to (same set
	# prepare.sh uses). A patch header cannot name its repo because a patch may
	# touch several files, and an unlinked checkout can hold an identical copy.
	CANDIDATE_REPOS=""
	for link in "$ROOT"/local-feeds/aw1000/*; do
		real="$(readlink -f "$link")"
		case "$real" in
		"$ROOT/src/"*)
			repo="${real#"$ROOT/src/"}"
			repo="${repo%%/*}"
			[ -d "$ROOT/src/$repo/.git" ] || continue
			case " $CANDIDATE_REPOS " in *" $repo "*) continue ;; esac
			CANDIDATE_REPOS="$CANDIDATE_REPOS $repo"
			;;
		esac
	done
	lpn=0
	while IFS= read -r p; do
		lpn=$((lpn + 1))
		name="$(basename "$p")"
		state=""
		for repo in $CANDIDATE_REPOS; do
			if git -C "$ROOT/src/$repo" apply --check -R "$p" 2>/dev/null; then
				state="applied:$repo"
				break
			fi
			if git -C "$ROOT/src/$repo" apply --check "$p" 2>/dev/null; then
				state="pending:$repo"
				break
			fi
		done
		case "$state" in
		applied:*) : ;; # applied, as expected after prepare.sh
		pending:*) bad "$name not applied to src/${state#pending:} (prepare.sh should have)" ;;
		*) bad "$name applies to no linked src/ checkout (stale against pin):$CANDIDATE_REPOS" ;;
		esac
	done < <(find "$LPF" -type f -name '*.patch' | sort)
	ok "$lpn local-feed patches verified against pinned src checkouts"
fi

# The image build ends with package/install, where apk refuses an invalid
# version string or two packages owning the same file - both fully knowable
# from the package metadata alone, but only after every package has compiled
# (~3 h). ci/check-packages.py evaluates exactly those two properties from
# openwrt/tmp/.packageinfo, so a regression fails here in about a second.
head2 "package metadata (apk)"
if [ ! -f "$ROOT/ci/check-packages.py" ]; then
	bad "ci/check-packages.py missing"
elif [ ! -f "$ROOT/ci/selftest-check-packages.sh" ]; then
	bad "ci/selftest-check-packages.sh missing"
elif bash "$ROOT/ci/selftest-check-packages.sh"; then
	ok "check-packages.py self-test passed"
else
	bad "check-packages.py self-test failed (the gate may no longer catch a regression)"
fi
if [ -f "$ROOT/ci/check-packages.py" ] && [ ! -f "$ROOT/openwrt/tmp/.packageinfo" ]; then
	bad "openwrt/tmp/.packageinfo missing - the apk metadata gate cannot run (prepare.sh runs 'make defconfig', which writes it)"
elif [ -f "$ROOT/ci/check-packages.py" ]; then
	pm_out="$(python3 "$ROOT/ci/check-packages.py" "$ROOT" 2>&1)"
	pm_rc=$?
	pm_fails=0
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		case "$line" in
		FAIL:*) bad "${line#FAIL: }"; pm_fails=$((pm_fails + 1)) ;;
		WARN:*) warn "${line#WARN: }" ;;
		*) ok "$line" ;;
		esac
	done <<<"$pm_out"
	# A non-zero exit without a FAIL line means the checker itself broke; do
	# not report it twice when it did print the reason.
	if [ "$pm_rc" != 0 ] && [ "$pm_fails" = 0 ]; then
		bad "ci/check-packages.py exited $pm_rc"
	fi
fi

head2 "overlay staged into openwrt/files"
if [ -d "$OVERLAY_DEV" ] && [ -d "$STAGED" ]; then
	miss=0
	while IFS= read -r src; do
		rel="${src#"$OVERLAY_DEV"/}"
		case "$rel" in *.b64) continue ;; esac
		if [ ! -e "$STAGED/$rel" ]; then
			bad "not staged: $rel"
			miss=$((miss + 1))
		fi
	done < <(find "$OVERLAY_DEV" -type f ! -name '*.b64' | sort)
	[ "$miss" = 0 ] && ok "every device overlay file reached openwrt/files"
	# Executable bits are what make init scripts and uci-defaults actually run.
	mod_n=0
	for d in etc/init.d etc/uci-defaults etc/hotplug.d/iface etc/hotplug.d/net etc/board.d usr/sbin; do
		[ -d "$STAGED/$d" ] || continue
		while IFS= read -r f; do
			mod_n=$((mod_n + 1))
			[ -x "$f" ] || bad "not executable: ${f#"$STAGED/"}"
		done < <(find "$STAGED/$d" -type f 2>/dev/null)
	done
	ok "$mod_n staged boot scripts executable"
	# Nothing that is only a repo transport detail may reach the rootfs.
	leak=0
	while IFS= read -r f; do
		leak=$((leak + 1))
		bad "transport file leaked into rootfs: ${f#"$STAGED/"}"
	done < <(find "$STAGED" -type f \( -name '*.b64' -o -name '*.orig' -o -name '*.rej' \) 2>/dev/null)
	[ "$leak" = 0 ] && ok "no transport/backup files in rootfs"
fi

head2 "vendor blob"
BLOB="$STAGED/etc/fxs/si3226x_patch.bin"
if [ -f "$BLOB" ]; then
	got="$(md5sum "$BLOB" | cut -d' ' -f1)"
	[ "$got" = "$BLOB_MD5" ] && ok "si3226x_patch.bin md5 $got" ||
		bad "si3226x_patch.bin md5 $got, expected $BLOB_MD5"
	[ "$(stat -c %a "$BLOB")" = 644 ] && ok "blob mode 644" || bad "blob mode $(stat -c %a "$BLOB"), want 644"
else
	bad "missing $BLOB"
fi
[ -f "$STAGED/etc/fxs/si3226x_patch.bin.b64" ] &&
	bad "base64 blob staged into rootfs (should be deleted by prepare.sh)"

head2 "theme, feeds and git hygiene"
THEME_MEDIA="$ROOT/openwrt/feeds/luci/themes/luci-theme-footstrap/htdocs/luci-static/footstrap"
[ -d "$THEME_MEDIA" ] && ok "footstrap media dir present" ||
	bad "missing $THEME_MEDIA (93-aw1000-theme would no-op)"
grep -q 'mediaurlbase' "$STAGED/etc/uci-defaults/93-aw1000-theme" 2>/dev/null &&
	ok "93-aw1000-theme staged" || bad "93-aw1000-theme not staged"
dangling=0
while IFS= read -r l; do
	dangling=$((dangling + 1))
	bad "dangling local-feeds link: ${l#"$ROOT/"}"
done < <(find "$ROOT/local-feeds" -type l ! -exec test -e {} \; -print 2>/dev/null)
[ "$dangling" = 0 ] && ok "all local-feeds links resolve"
if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
	if git -C "$ROOT" ls-files | grep -qx 'overlay/builder/devices/ipq807x-1g/files.ppe-nss/etc/fxs/si3226x_patch.bin'; then
		bad "decoded vendor blob is tracked in git"
	else
		ok "decoded vendor blob not tracked"
	fi
fi

printf '\n== summary ==\n'
printf '  %d fail, %d warn\n' "$fails" "$warns"
if [ "$fails" -gt 0 ]; then
	printf 'PRE-FLIGHT FAILED - do not push; fix the items above.\n'
	exit 1
fi
printf 'PRE-FLIGHT OK - the build definition is consistent (no compilation performed).\n'
