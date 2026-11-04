#!/usr/bin/env bash
# Clone every upstream source this build pins. Idempotent: re-running checks
# out the pinned commit again instead of re-downloading.
#
#   ./ci/bootstrap.sh            # fetch missing trees, pin the rest
#   ./ci/bootstrap.sh --refresh  # re-fetch even if already at the pin
#
# Everything lands where prepare.sh expects it:
#   openwrt/            openwrt-ppe-nss, branch ppe-nss
#   builder/            Qualcommax_NSS_Builder
#   src/<name>/         feed sources linked from local-feeds/aw1000/
#
# The openwrt/ and builder/ trees are git-ignored; this repo only tracks the
# overlay it copies on top of them.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

REFRESH=0
[ "${1:-}" = "--refresh" ] && REFRESH=1

# url | path | commit
# Commits are full SHAs on purpose: branch tips move, a firmware build must not.
SOURCES='
https://github.com/JuliusBairaktaris/openwrt-ppe-nss.git|openwrt|06531c585ded7c5ce00480b3dfbe90af748c2b08
https://github.com/JuliusBairaktaris/Qualcommax_NSS_Builder.git|builder|6bdd6b9621299c2996e1a4feaa998f615f7bbe1f
https://github.com/Perz3us/openwrt-aw1000-phone.git|src/aw1000_phone|f26f9f5a4bfbee391a3a15c9dab886c96d7ca539
https://github.com/Ace1337z/AW1000_BYTE.git|src/aw1000_byte|c3afe9132a20b908651d1d20ceef3de13341472f
https://github.com/dotywrt/dotycat-package.git|src/dotycat|fe9f2411189b53c66ddc4f1d91d436bde148923d
https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git|src/passwall-pkgs2|da712cf06cf4e6fd39e147fb36e6ec936003fcc9
'

at_pin() { # dir commit
	[ -d "$1/.git" ] || return 1
	[ "$(git -C "$1" rev-parse HEAD 2>/dev/null)" = "$2" ]
}

fetch_ref() { # dir url commit
	local dir=$1 url=$2 commit=$3
	if [ ! -d "$dir/.git" ]; then
		mkdir -p "$(dirname "$dir")"
		git init -q "$dir"
		git -C "$dir" remote add origin "$url"
	fi
	git -C "$dir" remote set-url origin "$url"
	# GitHub serves individual commits over both protocols; fall back to a
	# full fetch for servers that do not (local mirrors, older instances).
	if ! git -C "$dir" fetch -q --depth 1 origin "$commit" 2>/dev/null; then
		git -C "$dir" fetch -q origin "$commit" 2>/dev/null ||
			git -C "$dir" fetch -q --tags origin
	fi
	git -C "$dir" checkout -q --detach FETCH_HEAD 2>/dev/null ||
		git -C "$dir" checkout -q --detach "$commit"
}

while IFS='|' read -r url dir commit; do
	[ -n "$url" ] || continue
	if at_pin "$dir" "$commit" && [ "$REFRESH" = 0 ]; then
		echo "ok    $dir @ $commit"
		continue
	fi
	echo "fetch $dir @ $commit"
	fetch_ref "$dir" "$url" "$commit"
	got="$(git -C "$dir" rev-parse HEAD)"
	[ "$got" = "$commit" ] || {
		echo "ERROR: $dir is at $got, expected $commit" >&2
		exit 1
	}
done <<EOF
$SOURCES
EOF

# local-feeds/aw1000 links into what was just fetched.
"$ROOT/ci/links.sh"
echo "sources ready"
