# AW1000_NSS_BYTE

Custom OpenWrt firmware for the **Arcadyan AW1000** (IPQ8072A), built around
Qualcomm's NSS hardware offload. It is the modem stack from
[XT-Martinez/aw1000-feed](https://github.com/XT-Martinez/aw1000-feed) combined
with the TTL / MTU / IPv6 runtime from
[Ace1337z/AW1000_BYTE](https://github.com/Ace1337z/AW1000_BYTE), on the
NSS-EDMA tree, with **apk** as the package manager.

![Dashboard](docs/screenshots/dashboard.png)

The dashboard is `luci-mod-dashboard` with Footstrap's widget layout: link
state, modem registration and signal, CPU / NSS / Wi-Fi / modem temperatures,
CPU and memory, NSS-offloaded flow count, wireless clients, and five-minute
graphs for WAN traffic, modem traffic, signal, temperature, load and offload.

---

## What this is

| | |
|---|---|
| **Target** | `qualcommax` / `ipq807x` / Arcadyan AW1000, 1 GB RAM profile |
| **Base tree** | `JuliusBairaktaris/openwrt-ppe-nss`, branch `nss-edma-rework` |
| **NSS feed** | `xhikarishii/nss-packages`, branch `aw1000-nss` |
| **Package manager** | apk, unsigned (`--allow-untrusted`) |
| **Theme** | Footstrap, with a custom BYTE mark |
| **Default LAN** | `192.168.1.1` |
| **Default Wi-Fi** | SSID `BYTE`, open, both radios on |
| **Default root password** | empty |
| **Hostname** | `AW1000` |
| **Image name** | `AW1000_NSS_BYTE` (VERSION_DIST), version `1.0` |

Every source is pinned to a full 40-character SHA in `build/versions` and
`build/feeds`, so two builds of the same commit of this repo produce the same
image. Nothing follows a branch head.

---

## Building

The build is native - no container. `build/build.sh` fetches the pinned trees
into `work/` and runs the whole pipeline.

```sh
build/build.sh            # fetch, prepare, build
build/build.sh prepare    # stop after .config and the overlay
build/build.sh make menuconfig
build/build.sh make -j$(nproc)
build/build.sh clean      # remove work/
```

On Debian/Ubuntu install OpenWrt's build dependencies first; the exact list is
in `.github/workflows/build.yml`. Expect roughly 300 MB of downloads and
30-60 minutes on four cores.

GitHub Actions runs the same script on every push to `main`. The workflow
caches `work/openwrt/dl` and `work/openwrt/.ccache` between runs, and uploads
the images as the `aw1000-nss-byte-images` artifact.

### Output

```
openwrt-qualcommax-ipq807x-arcadyan_aw1000-squashfs-sysupgrade.bin
openwrt-qualcommax-ipq807x-arcadyan_aw1000-squashfs-factory.ubi
openwrt-qualcommax-ipq807x-arcadyan_aw1000-initramfs-uImage.itb
openwrt-qualcommax-ipq807x-arcadyan_aw1000.manifest
```

`build/release.sh` copies them out with fresh checksums, and refuses to
release if anything from an optional `private-files/` overlay leaked into the
image.

The initramfs image is for USB boot testing:
`usbboot 0x44000000 0:4` from U-Boot.

---

## Layout

```
aw1000/       package feed built from this repo
  aw1000-defaults/          LEDs, first-boot config (QModem owns the wwan iface)
  luci-app-modeminfo/       serving-cell page
  luci-app-custom/          the Custom page: NSS offload, AGH+PassWall2
byte/         runtime overlay: MTU, IPv6, tuning, branding
build/        build.sh, inside.sh, config, versions, feeds, patches
wwan/         qmi_wwan_q (the modem driver this image builds)
net/          udp-broadcast-relay-redux
docs/         screenshots and notes
```

The modem manager is **QModem**, pulled from its own feed (`build/feeds`,
pinned in `build/versions`) rather than vendored here: dialling, SMS, bands,
cell lock, the AT console and the modem UI all come from it, and the RJ11 phone
stack drives it through QModem's `ubus-at-daemon`.

`build/inside.sh` assembles `.config` from the builder's common config plus
`build/config`, runs `defconfig`, then **verifies** that every requested `=y`
symbol survived. A silently dropped package fails the build instead of shipping
an image with a missing feature.

---

## Modem

**QModem** owns the modem: dialling, reconnect, SMS, bands, cell lock, the AT
console and the modem UI (`Modem → QModem`, the JavaScript UI
`luci-app-qmodem-next`). The data path underneath it is unchanged: this repo
builds `qmi_wwan_q` (Quectel 1.5.0) with `qmap_mode=2`, so IPv4 lives on
`wwan0_1` and IPv6 on `wwan0_2`.

- QModem creates and owns the `network.wwan0` / `network.wwan0v6` interfaces
  (`proto qmodem_runtime`) and adds them to the `wan` zone itself. Nothing in
  `byte/` or `aw1000/` pre-creates a `wwan` interface - QModem refuses to dial
  through an interface it does not own, so a stale section would silently stop
  the uplink rather than be overwritten.
- `uqmi` and the upstream `qmi_wwan` are deliberately **excluded**: they claim
  the same Quectel USB IDs, and two drivers binding one modem is a coin flip at
  boot. `build/patches-openwrt/0003` removes `uqmi` from the device profile,
  and the build fails if a dependency brings it back.
- QModem ships its own copy of the same driver under the same binary package
  name. That copy is excluded (`build/feeds.exclude`) and all three QModem
  `INCLUDE_*` driver options are off (`build/config`): this repo's
  `qmi_wwan_q` is the one with the QMAP-netdev and raw-IP work the NSS offload
  needs (`docs/wwan-nss-offload.md`).

### AT ports

Nothing is pinned to a `ttyUSB` number. A port held open across a modem reset
can come back under a different name, so `aw1000-modem-ports` resolves the port
by USB interface number and vendor ID (`2c7c:0800`):

| Interface | Used by |
|---|---|
| 02 | QModem, `fxsd` (first AT port) |
| 03 | front-panel LEDs, dashboard cache |

`fxsd` finds interface 02 itself and passes the path to every
`ubus call at-daemon sendat`, so QModem's daemon needs no port configuration -
it opens a port on demand and keeps it open. The `/etc/config/ubus-at-daemon`
that the package ships is unused by this daemon version, and nothing here
writes it.

---

## IPv6

On by default, and demoted only when it is measurably broken.

Carriers routinely delegate a prefix and never route it. Clients then prefer
IPv6 (RFC 6724), send everything into a black hole, and the symptom is "the
internet is fine but nothing loads".

`byte-v6-check` does not guess from routes. It makes real `wget -6`
connections to three IPv6 literal targets, so nothing depends on DNS and a
broken resolver is distinguishable from broken routing. Only if all three fail
does it demote:

- writes `/etc/gai.conf` so `getaddrinfo` prefers IPv4
- disables LAN `ra` / `dhcpv6` so clients stop receiving a dead prefix
- flushes the ULA source off `br-lan`
- installs a `metric 2048` default route so IPv4 wins

It runs on every `ifup`, and `restore_ipv6` reverses all of it when a later
connection works. A carrier that fixes its IPv6 gets IPv6 back on the next
reconnect - nothing is permanent.

### Interface ownership

This is the part that has to differ from the upstream AW1000_BYTE build, and
the reason a straight copy of its IPv6 files does not work here.

AW1000_BYTE hardcodes a `wan` / `wanv6` pair: its `/etc/config/network`
declares `network.wan` with `modem_config '4_1'`, and its services wait on
`wanv6`. Upstream QModem's `03_qmodem` board file instead maps this board's USB
slot `4-1` to the alias `wwan0`, and `modem_dial.sh` only creates
`network.<alias>` when `qmodem_interface_owned()` agrees - it passes only when
`network.$1.modem_config` equals its own instance name, or when the section
does not exist at all.

So a hardcoded `wan`/`wanv6` would not be "overwritten by QModem". It would
leave this image with two uplinks - a `wan` interface QModem never dials and a
`wwan0` interface it does - fighting over the default route.

Every file here therefore resolves the alias from `/etc/config/qmodem` instead
of assuming a name:

| | |
|---|---|
| `byte-v6-check` | reads each `modem-device` section's `alias`, waits for `network.<alias>v6`, probes the alias netdev then the `wwan0_*` QMAP channels |
| `95-byte-v6` | triggers on `wan*`, `wwan*`, `*qmodem*` and `*v6`, so any alias QModem is configured with re-runs the check |
| `qmodem-iface-heal` | re-creates `network.<alias>` and `network.<alias>v6` under QModem's own `modem_config` tag and config lock, so QModem keeps ownership and keeps dialling |
| `byte-mtu`, `byte-selfcheck` | match the same broad interface set |

`byte-v6-check` writes `dhcp` and `gai.conf`, never `/etc/config/network`. The
NSS feed's `dhcp.lan` block stays `ra 'server'`; QModem only rewrites it to
`relay` when its `ra_master` option is set, which it is not on this board.

---

## Modem interface heal

QModem's `hang` → `flush_if` → `flush_ip_cb` path deletes every network
section tagged with the modem's `modem_config`, including the stop path procd
takes when `qmodem_network` restarts. If the dial worker never reaches
`set_if()` - SIM absent, netdev not enumerable, dial respawn throttled - the WAN
page is left blank until someone re-creates the interface by hand.

`qmodem-iface-heal` (START=95) polls every 2 s for the first two minutes and
every 20 s afterwards, and re-creates the pair with exactly the schema
`set_if()` would write. It follows the same ownership rule as QModem: a section
tagged with a *different* `modem_config` is left untouched rather than stolen,
and the whole read-modify-commit runs under QModem's own
`/var/lock/qmodem-config.lock` so it can never interleave with `set_if()`.


## TTL and offload

The TTL rewrite is the point of this image, and it is why NSS/ECM flow offload
is **off** by default.

TTL is owned by **one** package: QModem's `luci-app-qmodem-ttlfw4`. It installs
`qmodem_ttl`, which writes `/etc/nftables.d/99-reset-ttl-from-br-lan.nft` from
`/etc/config/qmodem_ttl` and is configured at `Modem → QModem → TTL`. Nothing
else in the image rewrites TTL:

| Package | What it does | State |
|---|---|---|
| `luci-app-qmodem-ttlfw4` | nftables postrouting rule from `/etc/config/qmodem_ttl` | **in the image** |
| `luci-app-qmodem-ttl` | the iptables flavour; `PKG_CONFLICTS` with the fw4 one, and depends on the legacy UI | excluded (`build/feeds.exclude`) |
| `luci-app-nft-ttl` (dotycat) | its own `ttl64.nft` on `iifname br-lan` | excluded |

ECM bypasses netfilter entirely, so offloaded flows keep their original TTL and
defeat the rewrite. The two are mutually exclusive on this box, and both
`qmodem_ttl` and `nss-offload` enforce it rather than trusting the user:

```sh
nss-offload on     # accelerate, but TTL is no longer guaranteed
nss-offload off    # TTL correct, modem path runs on the CPU
```

`qmodem_ttl` stops ECM when it starts. `nss-offload on` refuses to run while
`qmodem_ttl` is enabled, and the **Services → Custom** page shows the TTL state
read-only, links to the QModem page, and disables its own "Turn ON" button
while TTL is on.

The first-boot default is TTL 64 with the service enabled
(`byte/files/etc/uci-defaults/99-byte`).

The image ships with offload off. `kmod-rmnet-nss`, `NSS_DRV_RMNET_ENABLE` and
`NSS_DRV_C2C_ENABLE` are all present, so `nss-offload on` works - it is a
choice, not a limitation.

---

## Runtime overlay (`byte/`)

| | |
|---|---|
| `byte-mtu` + hotplug | Clamps `wwan0*` to MTU 1420. 1500 on an LTE/NR bearer is a PMTU blackhole: full-size packets are dropped upstream while small ones pass |
| `byte-v6` + `byte-v6-check` | IPv6 sanity, as above |
| `qmodem-iface-heal` | Re-creates `network.<alias>` / `network.<alias>v6` when QModem's flush has removed them and the dial worker has not put them back |
| `byte-affinity` | Spreads the modem's USB interrupts and RPS across all four cores. They otherwise all land on one core, which saturates long before the link does |
| `byte-selfcheck` | Verifies governor, `fq`/`bbr`, MTU probing, conntrack and socket buffers at boot and on `ifup`. Logs mismatches, does not fail the boot |
| `nss-offload` | `on` / `off` / `status` for NSS/ECM, with the same `qmodem_ttl` guard as the LuCI page |
| `etc/sysctl.conf` | `fq` + `bbr`, `tcp_fastopen=3`, `tcp_slow_start_after_idle=0`, `netdev_max_backlog=16384`, `netdev_budget=2400`, 4 MB socket buffers, 32768 conntrack entries |
| `etc/vnstat.conf` | `DatabaseDir "/etc/vnstat"` - the package default is tmpfs, so history would vanish on reboot |
| `etc/rc.local` | Brings up the phone port (PCM slave check, waits for the `at-daemon` ubus object, starts `fxsd`), spreads the modem IRQs across the cores, and self-heals `tailscale0` when Tailscale is installed. It deliberately does **not** re-assert the TTL rewrite or stop ECM: those are user choices, switched from `Modem → QModem → TTL` |
| `www/.../footstrap/` | BYTE logo and brand CSS |

`packet_steering` is **off**, matching the NSS feed's own default. Its comment
records 749/800 Mbit/s with steering off against 619/626 with it on, plus
`n2h_rx_queue` drops. Enable it by hand if you want it:

```sh
uci set network.@globals[0].packet_steering='1'
uci commit network && /etc/init.d/packet_steering restart
```

---

## Packages in the image

### LuCI

Ten `luci-app-*` packages are in the image. Everything else LuCI-side is a
library (`luci-lib-jsonc`, `luci-compat`), a protocol handler (`luci-proto-*`),
the theme, or the dashboard module.

| App | |
|---|---|
| `luci-app-qmodem-next` | the modem UI: dial, SMS, bands, cell lock, AT console |
| `luci-app-qmodem-sms` | QModem's messaging page |
| `luci-app-qmodem-ttlfw4` | the TTL rewrite (`Modem → QModem → TTL`) |
| `luci-app-modeminfo` | serving-cell / SA page |
| `luci-app-fxs` | RJ11 phone port: dialling, history, caller ID, SIP |
| `luci-app-custom` | the Custom page: NSS offload, AdGuard Home + PassWall2 | this repo |
| `luci-app-passwall2` | proxy, 26.4.10 |
| `luci-app-sqm` | Smart Queue Management |
| `luci-app-netstat` | live per-interface counters, connections |
| `luci-app-vnstat2` | long-term traffic graphs |
| `luci-app-ddns` | dynamic DNS |
| `luci-app-footstrap-files` | file manager for the theme |

Plus `luci-mod-dashboard` and `luci-theme-footstrap`.

### Proxy

Passwall2 **26.4.10** with **Xray-core 26.3.27**. The passwall dependency feed
is pinned at the commit carrying that Xray, not at its branch head - bump
`PASSWALL_PKGS_SHA` in `build/versions` to move it, and keep it in step with
the passwall2 tag.

Shadowsocks-Rust, ShadowsocksR, simple-obfs, v2ray-plugin, sing-box, hysteria
and tuic clients are all built in, as are `chinadns-ng`, `geoview`, `tcping`,
`haproxy` and `dnsmasq-full`.

QUIC/HTTP3 works through it: the conntrack helper, `nf-tproxy`/`nft-tproxy` and
`nf-socket`/`nft-socket` are present, and `filter_aaaa`/`filter_a` are off so
HTTPS/SVCB records reach clients.

### Other

`htop`, `iperf3`, `udp-broadcast-relay-redux`, `zram-swap` (433 MB, `lzo-rle`),
`vnstat2` + `vnstati2`, USB storage with exFAT/NTFS3/ext4.

### Built, published, not in the image

Compiled and published next to the image, so `apk add` works on a running
router. Each is either large or conflicts with something the image already
does:

| Package | Why not baked in | Install |
|---|---|---|
| `adguardhome`, `luci-app-adguardhome` | ~30 MB Go binary; also wants port 53, which passwall2 uses | `apk add --allow-untrusted adguardhome luci-app-adguardhome`, then **Services → AdGuard + PassWall2** |
| `tailscale`, `luci-app-tailscale-community` | `tailscaled` is ~13 MB of private RSS | `apk add --allow-untrusted tailscale luci-app-tailscale-community` |
| `luci-app-aw1k-led` | its `led-status` writes the same sysfs LEDs as `aw1000-leds` | see `build/config` |
| `luci-app-nikki` | same TPROXY/nftables hooks as passwall2 - one proxy at a time | `apk add --allow-untrusted luci-app-nikki` |
| `luci-app-openclash` | same conflict as nikki | `apk add --allow-untrusted luci-app-openclash` |
| `luci-app-nft-ttl` | own `ttl64.nft` + `br-lan` rule; `luci-app-qmodem-ttlfw4` already owns TTL. Excluded in `feeds.exclude` | drop that line and rebuild, but expect two rulesets rewriting the same packets |
| `luci-app-wol`, `etherwake` | wake-on-LAN needs a wired LAN peer to wake, and the cellular link is the WAN | `apk add --allow-untrusted luci-app-wol etherwake` |
| `luci-proto-wireguard`, `wireguard-tools` | a VPN client is a per-user choice, not a default on a cellular router | `apk add --allow-untrusted luci-proto-wireguard wireguard-tools` |
| `btop` | a second terminal monitor next to `htop`; image space for a duplicate | `apk add --allow-untrusted btop` |
| `qrencode` | only a few LuCI pages use it to draw QR codes | `apk add --allow-untrusted qrencode` |

Every dependency these declare is already in the image, so installing one does
not pull a dependency tree.

---

## RJ11 phone port

The phone stack is `kmod-aw1000-fxs` (SLIC driver), `fxsd` (dial tone,
ringing, DTMF, caller ID, SIP) and `luci-app-fxs`, pinned to
[Perz3us/openwrt-aw1000-phone](https://github.com/Perz3us/openwrt-aw1000-phone)
**v0.5.0** (`build/versions`, `PHONE_SHA`).

`fxsd` sends every AT command through `ubus call at-daemon sendat` - its direct
tty code is only a liveness probe, never a command path. `ubus-at-daemon` comes
from the QModem feed (3.4.x), which is why the two pins move together and why
`build/feeds.exclude` keeps that package out of nothing and `build/config`
selects it explicitly.

v0.5.0 adds SIP calling through QModem voice (`qmodem-voip` + `qmodem-sipd`),
configurable ring patterns, a start guard and caller-ID fixes. SIP is **off**
by default (`fxs.main.sip=0`) - turn it on in the phone page.

`/etc/rc.local` brings the port up in the background each boot: it clears a
stale guard, checks `AT+QDAI` and sets the modem's PCM to slave mode if needed,
waits for the `at-daemon` ubus object, then starts `fxsd`.

---

## Services → Custom

One page for the two things this image does differently from stock OpenWrt that
have no home of their own. Both would otherwise need an SSH session.

TTL is **not** here: it is QModem's own page (`Modem → QModem → TTL`), so there
is exactly one place that edits `/etc/config/qmodem_ttl`. The Custom page shows
its state read-only and links to it.

**NSS / ECM flow offload** — turn the fast path on or off. The page says
plainly why it and TTL are mutually exclusive: ECM bypasses netfilter, so
offloaded flows keep their original TTL. While `qmodem_ttl` is enabled the "Turn
ON" button is disabled and the enable call is refused server-side too, so the
guard does not depend on the UI. It also reports whether ECM is merely loaded
or actually accelerating (`accel_mode`).

**AdGuard Home + PassWall2** — a one-click wrapper around
[Ace1337z/openwrt-agh-passwall2](https://github.com/Ace1337z/openwrt-agh-passwall2):

```
LAN clients → router:53 (AdGuard Home: filtering)
                └→ 127.0.0.1:15353 (PassWall2: split DNS)
                └→ .lan / .local / .home.arpa → 127.0.0.1:54 (dnsmasq)
```

Both want to own DNS. Left alone they fight over port 53 and you get
"problem detected" from PassWall's hijack check, or `google.com` silently
resolving to forcesafesearch. The setup moves dnsmasq to :54, points AdGuard at
PassWall2, turns SafeSearch off, and has a revert button. The installer is
vendored rather than fetched at click time - a LuCI button should not pipe a
remote script into a root shell, and the router may have no WAN when pressed.
The only change from upstream is `apk add --allow-untrusted` first, since this
image builds unsigned packages.

---

## Compressed rootfs

The kernel here is built with `CONFIG_SQUASHFS_XZ=y` and nothing else, so zstd
is not an option - a zstd rootfs would not mount. Measured on a 502 MB tree of
ARM-ish binaries with the tree's own `mksquashfs` invocation:

| config | size | full extract |
|---|---|---|
| gzip 256K | 175.3 MiB | 640 ms |
| **xz 256K** | **140.8 MiB** | 2873 ms |
| xz 1024K | 134.4 MiB | 3375 ms |

xz at 256 KiB blocks: 20% smaller than gzip, and 1024 KiB would save only
6.4 MiB for 17% slower extraction plus 1 MiB read amplification per small file,
which LuCI has thousands of.

`build/inside.sh` prints the image size, rootfs size and ten largest files at
the end of every build, so a regression shows up in the log rather than at
flash time.

---

## Notes

- **`nss-edma-rework` is archived upstream.** Its README points at `ppe-nss`
  (kernel 6.18, PPE instead of EDMA, `nss-tools` moved into the feed). This repo
  stays on the archived branch because the proven AW1000 build follows it, and
  every package under `aw1000/`, `wwan/` and `net/` is byte-identical to it.
  Migrating is not a version bump: `build/patches-openwrt/0002` patches
  `package/nss/nss-tools`, which no longer exists there.
- **`build/patches-openwrt/0002` is a rebase.** The upstream version fails two
  of four hunks against the pinned tree; this one applies clean.
- **Packages are unsigned.** `apk add --allow-untrusted` is required for
  anything built here.
- **`build/config` is verified, not trusted.** If `defconfig` drops a requested
  symbol the build stops.

## Credits

Modem stack and dashboard widgets:
[XT-Martinez/aw1000-feed](https://github.com/XT-Martinez/aw1000-feed).
Modem manager: [FUjr/QModem](https://github.com/FUjr/QModem).
TTL/MTU/IPv6 runtime and the modem settings: [Ace1337z/AW1000_BYTE](https://github.com/Ace1337z/AW1000_BYTE).
NSS stack: [JuliusBairaktaris](https://github.com/JuliusBairaktaris).
Theme: [VizzleTF](https://github.com/VizzleTF/luci-theme-footstrap).
Phone port: [Perz3us](https://github.com/Perz3us/openwrt-aw1000-phone).
Netstat page: [Ace1337z](https://github.com/Ace1337z/luci-app-netstat).

Licences are those of the upstream projects; the AGH installer is MIT and is
noted in its directory. QModem is **MPL-2.0 plus a non-commercial
restriction** - that is not an OSI licence. It is fine for a personal build of
this image; re-read it before shipping the image anywhere money changes hands.
