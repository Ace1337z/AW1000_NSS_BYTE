# AW1000_NSS_BYTE Project Rules

## Build
- **Primary build command:** `./build/build.sh`
- **Never** run `make menuconfig` directly without first running `./build/build.sh prepare` to populate `work/openwrt`.
- **Verification:** The build fails if `defconfig` drops a requested `=y` symbol. Always check the build output for the verification step.

## Critical Runtime Rules
1.  **TTL vs. NSS Offload:** These are mutually exclusive. TTL rewriting requires netfilter; ECM/NSS bypasses it. The default is offload **off**. Do not enable offload unless TTL rewriting is explicitly not needed.
2.  **TTL ownership:** TTL is owned by exactly one package, QModem's `luci-app-qmodem-ttlfw4` (`/etc/config/qmodem_ttl`, `Modem → QModem → TTL`). Do **not** add a second TTL writer (`luci-app-nft-ttl`, `luci-app-qmodem-ttl`) and do **not** put TTL controls back into `luci-app-custom`. `/usr/bin/nss-offload on` refuses to run while `qmodem_ttl` is enabled - keep that guard.
3.  **Modem Drivers:** Use this tree's `wwan/qmi_wwan_q`. **Never** add `uqmi`, upstream `kmod-qmi_wwan`, or any QModem `INCLUDE_*` QMI driver option to the config - QModem's copy publishes the same `kmod-qmi_wwan_q` binary package name, so both in one build is a duplicate-package error. The build has a patch to prevent `uqmi` from returning.
4.  **Interface ownership:** QModem creates and owns `network.<alias>` / `network.<alias>v6` (`proto qmodem_runtime`), where `<alias>` comes from the `modem-device` section in `/etc/config/qmodem` (`wwan0` on this board). Do **not** hardcode `wan`/`wanv6` and do **not** pre-create an untagged interface - QModem's `qmodem_interface_owned()` refuses to dial through a section tagged with a foreign `modem_config`, and a hardcoded pair creates a second uplink that fights the real one over the default route. Anything that needs the uplink name must read `qmodem.<instance>.alias` (see `byte-v6-check`, `qmodem-iface-heal`).
5.  **Pinning:** Do not change `build/versions` or `build/feeds` from 40-character SHAs to branch names. `QMODEM_SHA` and `PHONE_SHA` must move together.

## Package Management
- The image uses **apk**. Unsigned packages require `--allow-untrusted`.

## Key Directories
- `byte/files/`: Runtime scripts (MTU, IPv6, affinity, selfcheck, phone bring-up).
- `aw1000/luci-app-custom/`: The "Services → Custom" page (NSS offload, AGH+PassWall2).
- `build/`: Build scripts and pinned configs.

## Experience Hints (for the agent)
- Before changing `build/versions`, run `git log -p build/versions` to see how SHAs are normally updated. Don't guess.
- If the build fails at patch `0002`, check `git log --oneline -- build/patches-openwrt/0002*` to see the rebase history. The patch is fragile.
- Before enabling offload, always state the TTL trade-off explicitly.
- Never remove the `uqmi` exclusion patch (`build/patches-openwrt/0003`).
- Never use a branch name where a 40-char SHA is expected.
