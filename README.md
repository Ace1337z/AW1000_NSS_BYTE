# AW1000_NSS_BYTE

Firmware for the **Arcadyan AW1000**: the aw1000-feed modem stack (XT) plus
the BYTE runtime (TTL/HopLimit rewrite, MTU clamp, IPv6 sanity, self-check,
RJ11 phone port), on the NSS-EDMA tree with **apk** as the package manager.

- Base: `JuliusBairaktaris/openwrt-ppe-nss`, branch `nss-edma-rework`
- NSS feed: `xhikarishii/nss-packages`
- Theme: footstrap + the luci-mod-dashboard widgets
- Package manager: apk (`--allow-untrusted`; packages are unsigned)
- Proxy: passwall2 installed by default; nikki and OpenClash are carried in
  the feeds and can be installed from LuCI afterwards (never two at once)
- Defaults: LAN `192.168.1.1`, SSID `BYTE` (open), root password empty

## Screenshots

Dashboard with the modem, temperature and NSS offload widgets:

![Dashboard](docs/screenshots/dashboard.png)

| Mobile tab | SMS |
|---|---|
| ![Dashboard mobile tab](docs/screenshots/dashboard-mobile.png) | ![SMS](docs/screenshots/sms.png) |
| **Cell lock** | **Bands** |
| ![Cell lock](docs/screenshots/cells.png) | ![Bands](docs/screenshots/bands.png) |

![AT commands](docs/screenshots/at.png)

Phone numbers, SIM and modem identifiers, addresses, cell IDs and the TAC
are masked.

## Packages

| Package | What it is |
|---|---|
| `kmod-qmi_wwan_q` | Quectel QMI WWAN driver 1.5.0 with QMAP multiplexing. Default `qmap_mode` is a menuconfig option (`QMI_WWAN_Q_QMAP_MODE`, default 2 → `wwan0_1`, `wwan0_2`). Built **without** its own rmnet_nss hooks: `qca-nss-drv` binds raw-IP modem netdevs itself (nss-packages `944ea25`), so the QMAP netdevs are always raw IP. See [docs/wwan-nss-offload.md](docs/wwan-nss-offload.md). |
| `quectel-cm` | quectel-cm 1.6.5 + netifd `quectel` proto: IPv4/IPv6 over separate QMAP channels (`option multiplexing 1`), passthrough, NAT64, handover monitor. |
| `luci-proto-quectel` | LuCI form for the `quectel` proto. |
| `luci-app-aw1000-modem` | The Modem pages (below): SMS conversations, bands, cell scan and lock, AT console. Ships `aw1000-at`, which sends one AT command and waits as long as it needs. |
| `udp-broadcast-relay-redux` | Relays UDP broadcasts between networks (e.g. Tapo camera discovery on port 20002 across lan/iot). Removed from openwrt/packages in `90b98c14f` (upstream archived); vendored unchanged. |
| `aw1000-defaults` | First-boot settings: `wwan` interface (APN `internet`, IPv4), front-panel LEDs, USB drive automount (`/mnt/<device>`), Footstrap theme. Runs once (marker `system.@system[0].aw1000_defaults`). Also ships `aw1000-leds`, `aw1000-modem-ports` and the dashboard widgets (below). |

| `ubus-at-daemon` | Ubus AT command daemon (`ubus call at-daemon sendat`). Vendored from FUjr/QModem `052f8447` (MPL-2.0), because fxsd drives the phone through it and the QModem repo is not a feed here. AT port defaults to `/dev/ttyUSB3`. |
| `kmod-aw1000-fxs` / `fxsd` / `luci-app-fxs` | The RJ11 phone port: SLIC kernel module, the daemon (DTMF, ringing, caller ID) and its LuCI page. From `Perz3us/openwrt-aw1000-phone`. |

`qmi_wwan_q` is Quectel's V1.5.0 as carried by FUjr/QModem `c49654e`
(builds on Linux 6.17+). `quectel-cm` and `luci-proto-quectel` are taken from
[xhikarishii/nss-packages](https://github.com/xhikarishii/nss-packages)
branch `aw1000-nss` at `ef05f5c` (GPL-2.0).

## Front panel

| LED | Meaning |
|---|---|
| signal (RGB) | LTE RSRP (the anchor on 5G NSA); steady green on 5G SA; off = no service |
| 5G (RGB) | NR RSRP on 5G SA or NSA; off on LTE only |
| internet | steady while fiber (`wan`) or the modem (`wwan`) can ping 1.1.1.1 / 8.8.8.8 |
| Wi-Fi | steady while the 5 GHz AP (`phy0-ap0`) is up |
| phone | blinks while there are messages not yet listed on Modem → Messages |

Quality colours: green ≥ −90 dBm, blue ≥ −105, red below.

Signal, 5G, internet and phone are driven by the `aw1000-leds` service, which
every 10 s polls `AT+QENG="servingcell"` and `+CPMS?` on the modem's second AT
port and pings out of each of `internet_ifaces` (`/etc/config/aw1000_leds`).

## Modem pages

LuCI's Modem menu is `luci-app-aw1000-modem`:

| Page | What |
|---|---|
| Messages | SMS as conversations: modem and SIM memory (a fill bar each), long messages put together, sent ones kept on the router (`/etc/aw1000-modem/sms-sent`); where new messages are stored (modem or SIM) |
| Bands | network mode, 5G NSA/SA, and the LTE / 5G NSA / 5G SA bands (`AT+QNWPREFCFG`), the ones in use marked |
| Cell lock | serving cell, LTE and 5G SA cell locks, neighbour list, full scan of every operator's cells (`AT+QSCAN`, about 100 s) |
| AT commands | console with history and common commands; slow ones run in the background |

The backend is the rpcd plugin `luci.aw1000-modem`. Settings are in
`/etc/config/aw1000_modem`: the cell locks, which the `quectel` proto sends
to the modem on every connect (they used to be its `cell_lock_4g` option),
the SMS country code (`0917…` is sent as `+63917…`: Smart's SMS centre
refuses national numbers) and the storage for new messages, which
`aw1000-leds` restores after a modem restart.

Every AT user takes the modem's lock, `/var/lock/aw1000-modem.lock`: all
ports lead to one command parser. The AT ports are chosen by USB interface,
not by `ttyUSB` number (`aw1000-modem-ports`): interface 2 for the pages,
interface 3 for `aw1000-leds`. A modem reset that renumbers the ports
(`ttyUSB3` → `ttyUSB4`) needs no manual fix.

## Dashboard widgets

`aw1000-defaults` adds widgets to `luci-mod-dashboard` (plain files in its
`view/dashboard/include/`, no patch):

| Widget | Card | Chart | Tab |
|---|---|---|---|
| `mobile` (`40_mobile.js`) | LTE / 5G NSA / 5G SA, operator, bands, RSRP, connected or standby | LTE and 5G RSRP and SINR, last 5 min | carriers (band, bandwidth, PCI, ARFCN, RSRP/RSRQ/SINR), cell ID, TAC, APN, addresses, band and cell locks (linked to the Bands and Cell lock pages), SIM, firmware, modem temperature |
| `mobile-traffic` (`40_mobile.js`) | | down/up over `wwan0_N`, NSS-offloaded traffic included | |
| `thermal` (`45_thermal.js`) | CPU, NSS, Wi-Fi, modem °C | the same, last 5 min | |
| `nss` (`48_nss.js`) | connections offloaded to the NSS firmware (ECM, IPv4 / IPv6) | the same, last 5 min | |

The modem takes one AT command at a time, so the widgets never query it: `aw1000-leds` saves its replies and the temperatures to
`/tmp/aw1000-status/` every poll (`live`, `static` once a minute, `history`,
`thermal`, `nss`), and the widgets read those files (ACL
`luci-aw1000-dashboard`). Parsing and the signal icons are shared with the
modem pages in `aw1000/cell.js`; a reading's colour gives its quality (good,
fair, poor), named in its tooltip. The NSS firmware's load figure
(`stats/cpu_load_ubi`) is not shown: qca-nss-drv only refreshes it while
the NSS clock scales itself, which this build leaves off, so it stays at its
boot value. A saved layout (Dashboard → Layout) lists widgets
by id; new ids only show once added there.

## Build

No containers: `build/build.sh` clones the pinned trees into `work/` and
builds natively. On Ubuntu/Debian install OpenWrt's build dependencies first
(the same list `.github/workflows/build.yml` installs).

```sh
build/build.sh            # fetch pinned trees, feeds, config, full build
build/build.sh prepare    # stop after .config + overlay (no make)
build/build.sh make menuconfig
build/build.sh make -j$(nproc)
build/build.sh clean      # remove work/
```

CI (`.github/workflows/build.yml`) runs the same script on push to `main`;
images are uploaded as the `aw1000-nss-byte-images` artifact. `work/openwrt/dl`
and `work/openwrt/.ccache` are cached between runs.

All trees are pinned to full 40-char SHAs in `build/versions`; bump one line
at a time - the patches fail loudly (not silently) when they stop applying.

- `build/feeds` — feeds added to `feeds.conf.default`, in install order.
- `build/feeds.prefer` — packages taken from a given feed when several carry
  them (`sms-tool` from 4IceG's repo).
- `build/feeds.exclude` — installed feed packages removed again.
- `build/config` — appended to `builder-reference/devices/common/config`.
- `build/versions` — pinned SHAs for the base tree, nss feed and builder ref.
- `byte/files/` — the BYTE runtime overlay (below), copied into the image.
- `build/patches/<feed>/` — patches applied to `feeds/<feed>`.
- `build/patches-openwrt/` — patches applied to the OpenWrt tree itself.
- `build/patches-nss/<package>/` — extra package patches for the `nss` feed,
  copied next to the package's own (the feed becomes a writable copy).

## BYTE runtime (`byte/`)

Ported from `Ace1337z/AW1000_BYTE` and adapted from qmodem to this image's
quectel-cm + `qmi_wwan_q` data path.

| Piece | What it does |
|---|---|
| `etc/init.d/byte-ttl` | TTL/HopLimit rewrite for modem egress. An `inet forward` chain at priority `mangle`, matching the **output** interface (`wwan0_1`, `wwan0_2`) rather than `iifname br-lan`, so only traffic actually leaving through the modem is touched. Config in `/etc/config/byte_ttl` (`ttl`, `ttl4`, `hl6`, `meta_mode`). Writes `/etc/nftables.d/90-byte-ttl.nft`. |
| `etc/init.d/byte-mtu` + `90-byte-mtu` | Clamps `wwan0`/`wwan0_1`/`wwan0_2` to MTU 1420. A 1500-byte MTU on an LTE/NR bearer is a PMTU blackhole: full-size packets are dropped upstream while small ones pass, which stalls large transfers and VoIP. Re-applied on every `ifup`. |
| `etc/init.d/byte-v6` + `byte-v6-check` | Keeps IPv6 enabled, but demotes it to IPv4 when the carrier delegates a prefix with no routable WAN address. Without it clients prefer a dead IPv6 path and "the internet is fine but nothing loads". |
| `etc/init.d/byte-affinity` | Spreads modem packet processing (RPS/XPS on `wwan*`, `rmnet*`, `br-lan`) across all four cores. The modem's USB interrupts otherwise all land on one core, which saturates long before the link does once passwall2 is doing userspace crypto. |
| `etc/init.d/byte-selfcheck` | Verifies the tuning at boot and on every `ifup`: governor pinned, `fq`/`bbr`, MTU probing, conntrack and socket buffer ceilings. Logs `byte-selfcheck: OK` or the mismatches - it does not fail the boot. |
| `etc/init.d/byte-tailscale-gate` + `byte-ts-should-start` | Starts `tailscaled` only once a state file with real credentials exists, instead of holding ~13 MB of private RSS on routers that never use it. Fails open: anything ambiguous means start. |
| `usr/bin/nss-offload` | `nss-offload on\|off\|status` toggles NSS/ECM flow offload. **Off by default**: ECM bypasses netfilter, so offloaded flows keep their original TTL and defeat the rewrite. |
| `etc/rc.local` | Every boot: re-asserts the TTL service and ECM-off, then brings up the RJ11 phone port in the background (PCM slave check via `AT+QDAI`, waits for the `at-daemon` ubus object, starts `fxsd`) and self-heals `tailscale0` when it comes up with no address. |
| `etc/sysctl.conf` | `fq`/`bbr`, MTU probing, 4 MB socket buffers and 32768 conntrack entries - sized from the bandwidth-delay product of a 300 Mbit/s, 60 ms link, not from server defaults. |
| `etc/config/wireless` | SSID `BYTE`, open, both radios on, 5 GHz HE80 ch149 / 2.4 GHz HE20 ch1. |
| `etc/config/system` | Hostname `AW1000`, zram on `lzo-rle` (the only algorithm this kernel ships), NTP. |

Deliberately **not** carried over from BYTE: the hourly `drop_caches` +
`swapoff/swapon` cron (it throws away a warm page cache and stalls every
process touching zram), the ImmortalWrt opkg feed script (this image is apk),
and `qmodem-iface-heal` (quectel-cm does not delete `network.wan` on redial).

`etc/uci-defaults/98-byte` applies the runtime defaults once, guarded by
`system.@system[0].byte_defaults`, so it survives a settings-keeping
sysupgrade. Clear that option to have it re-applied:

```sh
uci delete system.@system[0].byte_defaults && uci commit system
```

## Installing packages

The image uses **apk**. Feed packages built here are unsigned, so install
them with:

```sh
apk add --allow-untrusted <package>
```

Nikki and OpenClash are carried in the tree but not installed, because they
install the same TPROXY/nftables hooks as passwall2. Only one of the three may
be active at a time.
