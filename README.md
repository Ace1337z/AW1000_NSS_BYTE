# AW1000_NSS_BYTE

BYTE-branded OpenWrt **ppe-nss** (NSS hardware offload) firmware for the
**Arcadyan AW1000** (Qualcomm IPQ807x, 5G CPE).

This repo is the build definition only: it pins the upstream trees, overlays the
device files, and asks CI (or a local run) to produce one squashfs sysupgrade
image. `openwrt/`, `builder/` and `src/` are fetched by `ci/bootstrap.sh` and are
not tracked here.

- Target: `qualcommax/ipq807x`, profile `arcadyan_aw1000`
- Image: squashfs, sysupgrade only (no factory image)
- Release: tag `BYTE-1.0.x`, title `BYTE 1.0.x`
- Details, risks and the full verification checklist: [README-BUILD.md](README-BUILD.md)

## Layout

| path | what |
| --- | --- |
| `VERSION` | release version (`1.0.x`); drives the tag and the release name |
| `prepare.sh` | syncs the overlay onto `builder/`, decodes vendor blobs, generates feeds + `.config` |
| `build.sh` | `make download`, `make`, then stages `releases/BYTE-<version>/` |
| `ci/bootstrap.sh` | clones `openwrt`, `builder`, `src/*` at the pinned commits |
| `ci/links.sh` | creates the `local-feeds/aw1000` links into `src/` |
| `ci/preflight.sh` | fast consistency gate: config symbols, patch application, overlay staging, script/JSON syntax (no compilation) |
| `overlay/builder/` | our additions to Qualcommax_NSS_Builder (device files, patches, config fragment) |
| `local-feeds/aw1000/` | vendored feed packages (dashboard, BYTE panel, passwall2) |
| `.github/workflows/build.yml` | CI build + release publish |

## Build locally

```sh
./ci/bootstrap.sh      # pinned clones: openwrt, builder, src/*
./prepare.sh           # feeds + .config + overlay; fails on dropped symbols
./ci/preflight.sh      # seconds, no compilation: symbols, patches, staging, syntax
JOBS=2 ./build.sh      # the only step that compiles; image in openwrt/bin/targets/...
```

Result: `releases/BYTE-1.0.1/BYTE-1.0.1-arcadyan_aw1000-squashfs-sysupgrade.bin`
plus `sha256sums` and `RELEASE.md`.

## Flash

There is **no factory image**. The device must already run OpenWrt, or be
recovered to it over serial/TFTP first.

```sh
sysupgrade -n BYTE-1.0.1-arcadyan_aw1000-squashfs-sysupgrade.bin
```

`-n` discards settings and is required for the first flash. Before you flash:
keep a serial console or the vendor TFTP recovery path reachable, and a
known-good image plus a config backup. A failed sysupgrade on this board is
recoverable over serial/TFTP, not over the network alone.

## Default access after flash

| what | value |
| --- | --- |
| LAN address | `192.168.1.1/24` (DHCP server on) |
| LuCI | `http://192.168.1.1/` (HTTPS also on `:443`, stock cert auto-generated) |
| LuCI / SSH user | `root` |
| LuCI / SSH password | *(empty — no password)* |
| Hostname | `BYTE` (`BYTE by ACE`) |
| Wi-Fi SSID | `BYTE` (2.4 GHz and 5 GHz, same name) |
| Wi-Fi password | *(none — open network)* |
| Wi-Fi country | `US` |
| LuCI theme | Footstrap (default; Bootstrap still installed as fallback) |
| SSH | `ssh root@192.168.1.1` (blank password accepted) |
| Phone/SIP extension | user `byte`, random password in `/root/SIP-CREDENTIALS.txt` (mode 0600) |

Firewall: WAN-side input is dropped as in stock OpenWrt, so LuCI/SSH are
reachable from LAN only. The BYTE panel is under **Services → BYTE**.

> **Security warning.** The WLAN is open (no passphrase) and the root account
> has an empty password, both by design for first boot. Anyone in radio range
> can join the network, and anyone on the network can log in as `root`. Set a
> Wi-Fi passphrase (`wireless.@wifi-iface[0].encryption=psk2` +
> `wireless.@wifi-iface[0].key=...`) and a root password (`passwd`) before
> putting this device on an untrusted network. Do not port-forward LuCI or SSH.

## CI

Push to `main` (or run the workflow manually) and GitHub Actions builds the
image and publishes it as the release named in `VERSION`. The job uploads the
sysupgrade image, `sha256sums` and `RELEASE.md`, and fails if the image is
missing or the release carries no sysupgrade asset.

## Notes

- `si3226x_patch.bin` is the Skyworks ProSLIC DSP patch used by the stock
  firmware. It is stored base64 (`si3226x_patch.bin.b64`) so the repository stays
  text-only; `prepare.sh` decodes it. It is third-party vendor code and this
  repository redistributes it — check whether that is acceptable for your use.
