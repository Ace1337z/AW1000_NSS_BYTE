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
  aw1000-defaults/          wwan interface, LEDs, first-boot config
  luci-app-aw1000-modem/    SMS, bands, cell scan/lock, AT console
  luci-app-modeminfo/       serving-cell page
  luci-app-agh-passwall2/   one-click AdGuard Home + PassWall2 DNS setup
  ubus-at-daemon/           AT transport for the phone port (vendored)
byte/         runtime overlay: TTL, MTU, IPv6, tuning, branding
build/        build.sh, inside.sh, config, versions, feeds, patches
wwan/         qmi_wwan_q, quectel-cm, luci-proto-quectel
net/          udp-broadcast-relay-redux
docs/         screenshots and notes
```

`build/inside.sh` assembles `.config` from the builder's common config plus
`build/config`, runs `defconfig`, then **verifies** that every requested `=y`
symbol survived. A silently dropped package fails the build instead of shipping
an image with a missing feature.

---

## Modem

`qmi_wwan_q` (Quectel 1.5.0) with `qmap_mode=2`, driven by `quectel-cm` through
netifd's `quectel` protocol.

- IPv4 on `wwan0_1`, IPv6 on `wwan0_2`, the IPv6 call coming up as the dynamic
  `wwan_6`
- `uqmi` and the upstream `qmi_wwan` are deliberately **excluded**: they claim
  the same Quectel USB IDs, and two drivers binding one modem is a coin flip at
  boot. `build/patches-openwrt/0003` removes `uqmi` from the device profile,
  and the build fails if a dependency brings it back.

### AT ports

Nothing is pinned to a `ttyUSB` number. A port held open across a modem reset
can come back under a different name, so `aw1000-modem-ports` resolves the port
by USB interface number and vendor ID (`2c7c:0800`):

| Interface | Used by |
|---|---|
| 02 | LuCI modem pages, `fxsd`, `ubus-at-daemon` |
| 03 | front-panel LEDs, dashboard cache |

---

## IPv6

On by default, and demoted only when it is measurably broken.

Carriers routinely delegate a prefix and never route it. Clients then prefer
IPv6 (RFC 6724), send everything into a black hole, and the symptom is "the
internet is fine but nothing loads".

`byte-v6-check` does not guess from routes. It makes real `wget -6`
connections to three literal targets - two IPv6 literals plus a hostname, so a
broken resolver is distinguishable from broken routing. Only if all three fail
does it demote:

- writes `/etc/gai.conf` so `getaddrinfo` prefers IPv4
- disables LAN `ra` / `dhcpv6` so clients stop receiving a dead prefix
- flushes the ULA source off `br-lan`
- installs a `metric 2048` default route so IPv4 wins

It runs on every `ifup`, and `restore_ipv6` reverses all of it when a later
connection works. A carrier that fixes its IPv6 gets IPv6 back on the next
reconnect - nothing is permanent.

---

## TTL and offload

The TTL rewrite is the point of this image, and it is why NSS/ECM flow offload
is **off** by default.

`byte-ttl` installs an `inet forward` chain at priority `mangle`, matching the
**output** interface (`wwan0_1`, `wwan0_2`). That is the correct hook for
"everything leaving through the modem" - a rule keyed on `iifname br-lan` also
rewrites LAN-to-LAN traffic and is what `luci-app-nft-ttl` does.

ECM bypasses netfilter entirely, so offloaded flows keep their original TTL and
defeat the rewrite. The two are mutually exclusive on this box:

```sh
nss-offload on     # accelerate, but TTL is no longer guaranteed
nss-offload off    # TTL correct, modem path runs on the CPU
```

The image ships with it off. `kmod-rmnet-nss`, `NSS_DRV_RMNET_ENABLE` and
`NSS_DRV_C2C_ENABLE` are all present, so `nss-offload on` works - it is a
choice, not a limitation.

---

## Runtime overlay (`byte/`)

| | |
|---|---|
| `byte-ttl` | TTL / HopLimit rewrite on modem egress. Config in `/etc/config/byte_ttl` |
| `byte-mtu` + hotplug | Clamps `wwan0*` to MTU 1420. 1500 on an LTE/NR bearer is a PMTU blackhole: full-size packets are dropped upstream while small ones pass |
| `byte-v6` + `byte-v6-check` | IPv6 sanity, as above |
| `byte-affinity` | Spreads the modem's USB interrupts and RPS across all four cores. They otherwise all land on one core, which saturates long before the link does |
| `byte-selfcheck` | Verifies governor, `fq`/`bbr`, MTU probing, conntrack and socket buffers at boot and on `ifup`. Logs mismatches, does not fail the boot |
| `byte-tailscale-gate` | Starts `tailscaled` only once a state file with credentials exists, instead of holding ~13 MB of RSS on routers that never use it. Fails open |
| `nss-offload` | `on` / `off` / `status` for NSS/ECM |
| `etc/sysctl.conf` | `fq` + `bbr`, `tcp_fastopen=3`, `tcp_slow_start_after_idle=0`, `netdev_max_backlog=16384`, `netdev_budget=2400`, 4 MB socket buffers, 32768 conntrack entries |
| `etc/vnstat.conf` | `DatabaseDir "/etc/vnstat"` - the package default is tmpfs, so history would vanish on reboot |
| `etc/rc.local` | Re-asserts TTL and ECM-off each boot, brings up the phone port, self-heals `tailscale0` |
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

| App | |
|---|---|
| `luci-app-aw1000-modem` | SMS conversations, bands, cell scan and lock, AT console |
| `luci-app-modeminfo` | serving-cell / SA page |
| `luci-app-fxs` | RJ11 phone port: dialling, history, caller ID |
| `luci-app-agh-passwall2` | one-click AdGuard Home + PassWall2 DNS setup |
| `luci-app-passwall2` | proxy, 26.4.10 |
| `luci-app-sqm` | Smart Queue Management |
| `luci-app-netstat` | live per-interface counters, connections |
| `luci-app-vnstat2` | long-term traffic graphs |
| `luci-app-ddns` | dynamic DNS |
| `luci-app-wol` | wake-on-LAN |
| `luci-app-footstrap-files` | file manager for the theme |

Plus `luci-mod-dashboard`, `luci-theme-footstrap`, `luci-proto-quectel` and
`luci-proto-wireguard`.

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

`btop`, `htop`, `iperf3`, `wireguard-tools`, `qrencode`, `etherwake`,
`udp-broadcast-relay-redux`, `zram-swap` (433 MB, `lzo-rle`), `vnstat2` +
`vnstati2`, USB storage with exFAT/NTFS3/ext4.

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
| `luci-app-nft-ttl` | own `ttl64.nft` + `br-lan` rule; `byte-ttl` already owns this. Excluded in `feeds.exclude` | drop that line and rebuild |

Every dependency these declare is already in the image, so installing one does
not pull a dependency tree.

---

## RJ11 phone port

Works **without** QModem. The phone stack is `kmod-aw1000-fxs` (SLIC driver),
`fxsd` (dial tone, ringing, DTMF, caller ID), `luci-app-fxs`, and
`ubus-at-daemon`.

The confusion is reasonable: the upstream project says "QModem (fxsd sends AT
commands through its at-daemon)". But the dependency is on the *daemon*, not on
QModem the modem manager. `fxsd` sends every AT command through
`ubus call at-daemon sendat` - its direct tty code is only a liveness probe,
never a command path. `ubus-at-daemon` is ~100 KB, opens a tty, writes an AT
command and returns the answer over ubus. It is vendored here from FUjr/QModem
`052f8447` (MPL-2.0).

`/etc/rc.local` brings the port up in the background each boot: it clears a
stale guard, checks `AT+QDAI` and sets the modem's PCM to slave mode if needed,
waits for the `at-daemon` ubus object, then starts `fxsd`.

---

## AdGuard Home + PassWall2

Both want to own DNS. Left alone they fight over port 53 and you get
"problem detected" from PassWall's hijack check, or `google.com` silently
resolving to forcesafesearch.

**Services → AdGuard + PassWall2** is a one-click wrapper around
[Ace1337z/openwrt-agh-passwall2](https://github.com/Ace1337z/openwrt-agh-passwall2):

```
LAN clients → router:53 (AdGuard Home: filtering)
                └→ 127.0.0.1:15353 (PassWall2: split DNS)
                └→ .lan / .local / .home.arpa → 127.0.0.1:54 (dnsmasq)
```

It moves dnsmasq to :54, points AdGuard at PassWall2, turns SafeSearch off, and
has a revert button. The installer is vendored rather than fetched at click
time - a LuCI button should not pipe a remote script into a root shell, and the
router may have no WAN when pressed. The only change from upstream is
`apk add --allow-untrusted` first, since this image builds unsigned packages.

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

Modem stack, dashboard widgets and modem pages:
[XT-Martinez/aw1000-feed](https://github.com/XT-Martinez/aw1000-feed).
TTL/MTU/IPv6 runtime: [Ace1337z/AW1000_BYTE](https://github.com/Ace1337z/AW1000_BYTE).
NSS stack: [JuliusBairaktaris](https://github.com/JuliusBairaktaris).
Theme: [VizzleTF](https://github.com/VizzleTF/luci-theme-footstrap).
Phone port: [Perz3us](https://github.com/Perz3us/openwrt-aw1000-phone).
Netstat page: [Ace1337z](https://github.com/Ace1337z/luci-app-netstat).

Licences are those of the upstream projects; vendored `ubus-at-daemon` is
MPL-2.0 and the AGH installer is MIT, both noted in their directories.
