# CAKE upload shaping on UniFi gateways

UCG Ultra how-to, plus an untested UDM Pro adaptation.

Rohan Muscat, 16 November 2026

## What this does

Upload on the WAN is shaped by CAKE, download stays on UniFi's stock HTB + fq_codel shaper, and both rates are still set in the UniFi GUI under Smart Queues. A small script on the gateway does the swap and keeps it in place.

- **Tested on:** UniFi Cloud Gateway Ultra, firmware 6.0.17, kernel 5.4.213-ui-ipq5322, WAN on `eth4` with a plain IP (DHCP) connection, 500/50 Mbps service, 16 November 2026.
- **Not tested:** the UDM Pro section. It is an adaptation with checks that tell you early whether it will work.
- **Unsupported:** Ubiquiti does not support any of this. The SSH login banner warns that CLI modifications outside normal operation void the warranty.

Why bother: CAKE adds per-device fairness behind NAT and its own priority tiers, on the direction that saturates first on an asymmetric link. Shaping 50 Mbps of upload is light work for the gateway CPU.

Download shaping is the expensive direction. [Ubiquiti's own guidance](https://help.ui.com/hc/en-us/articles/12648661321367) is to avoid Smart Queues on connections of 300 Mbps or more, so on a fast link expect download shaping to cost CPU and possibly throughput. This setup keeps it anyway, by choice.

## How it works

UniFi keeps building its normal Smart Queues shapers, and a script swaps the upload one for CAKE at the same rate. The GUI stays the source of truth because the script reads the rate from the shaper UniFi just built.

![Traffic paths through the WAN port: upload goes through CAKE, download goes through the ingress hook and ifbeth4](images/traffic-paths.svg)

Upload leaves through CAKE. Download arrives at the ingress hook and is redirected through `ifbeth4`, exactly as stock.

What Smart Queues builds on the UCG Ultra (read from `tc` on the tested unit):

- **Upload, on the WAN port's outgoing side:** an HTB shaper. Its root class `1:1` carries the GUI upload rate, with two child classes (`1:2` default and `1:4` high priority), each feeding an fq_codel queue.
- **Download, on the WAN port's incoming side:** an ingress hook with one filter. It runs a `connmark` action, then redirects every packet to a virtual device named `ifb<wan>` (`ifbeth4` here). That device has its own HTB + fq_codel at the GUI download rate.

What the script does, once a minute:

1. Looks at the root queue on the WAN port.
2. If it is `htb`, UniFi has just built or rebuilt its shaper. The script reads the rate from the `class htb 1:1 root rate ...` line and runs `tc qdisc replace` to put CAKE there at that rate.
3. If it is `cake`, it does nothing.
4. If it is anything else, Smart Queues is off in the GUI, and it does nothing.

The download side is never touched.

Changing the upload figure in the GUI makes UniFi rebuild its HTB shaper, and the script converts it within a minute. This was observed during setup: after a GUI change the CAKE handle moved from `8003:` to `8004:` and its bandwidth followed the new figure.

If the script stops running, the gateway falls back to stock Smart Queues the next time UniFi applies its settings.

## UCG Ultra: preflight checks

Run these before installing anything. Each one confirms an assumption the script depends on.

**1. Smart Queues is on.** In the UniFi GUI, open the WAN's settings, enable Smart Queues and enter your upload and download rates. The minimum the GUI accepts for download is 1 Mbps, so download shaping cannot be switched off from there.

**2. SSH in as root** and find the WAN interface:

```bash
ip -br addr | grep -E 'eth|ppp'
```

The WAN is the interface holding your ISP address. On the tested unit it is `eth4`, with a companion `ifbeth4`. If a `ppp0` interface appears, the connection is PPPoE. See the limits section before going further.

**3. CAKE is available.** This tests the kernel module and the `tc` tool on an unused interface, so live traffic is not affected:

```bash
modprobe sch_cake; lsmod | grep cake
tc qdisc replace dev dummy0 root cake && tc qdisc show dev dummy0
tc qdisc del dev dummy0 root
```

Expected: a `sch_cake` line from `lsmod`, then a line starting `qdisc cake`. On firmware 6.0.17 both worked.

**4. The stock layout matches.** With Smart Queues on and no CAKE yet:

```bash
tc qdisc show dev eth4
tc class show dev eth4 | grep root
tc filter show dev eth4 parent ffff: | grep -i redirect
```

Expected, with a 50 Mbps upload setting:

```
qdisc htb 1: root refcnt 5 r2q 10 default 0x2 ...
class htb 1:1 root rate 50Mbit ceil 50Mbit burst 1500b cburst 1500b
        action order 2: mirred (Egress Redirect to device ifbeth4) stolen
```

The `class htb ... root rate` line is the one the script reads. If it is missing or looks different, stop here.

**5. Take a baseline.** Run a bufferbloat test (Waveform's is the common one) and note the speeds and latency grades, so you have something to compare against.
## UCG Ultra: install

One paste creates the script and the service, checks the script's syntax, and starts it. The script lives in `/data/cake-upload/` and the service unit in `/etc/systemd/system/`, with a spare copy of the unit kept in `/data`. The same two files are in this repo as `cake-upload.sh` and `cake-upload.service` if you would rather copy them across.

If your WAN is not `eth4`, change the `WAN_IF` line before pasting.

```bash
mkdir -p /data/cake-upload

cat << 'EOF' > /data/cake-upload/cake-upload.sh
#!/bin/bash
# cake-upload.sh
#
# What this does:
#   UniFi Smart Queues stays switched on in the GUI and remains the place
#   where the upload and download limits are set. Once a minute this script
#   checks the WAN port. If it finds UniFi's own upload shaper (HTB +
#   fq_codel) there, it:
#     1. reads the upload rate UniFi configured,
#     2. replaces that upload shaper with CAKE at the same rate.
#   If CAKE is already in place it changes nothing.
#   Download is left alone: UniFi keeps shaping it with HTB + fq_codel
#   on the ifb device.
#
# Fail-safe: if this script stops, UniFi's stock Smart Queues comes back
# the next time UniFi applies its settings (or at the next reboot).
#
# Logs: journalctl -t cake-upload   (only written when something changes)

WAN_IF="eth4"                 # WAN port to shape (check with: ip -br addr)
CAKE_OPTS="nat ethernet"      # nat      = per-device fairness behind NAT
                              # ethernet = Ethernet frame overhead accounting
CHECK_EVERY=60                # seconds between checks

log() { logger -t cake-upload "$*"; }

# Prints the type of the root (outgoing) qdisc on the WAN port: htb, cake, mq...
root_kind() {
    tc qdisc show dev "$WAN_IF" | awk '$4=="root"{print $2; exit}'
}

# Prints the upload rate UniFi set, taken from the line
#   "class htb 1:1 root rate 50Mbit ceil 50Mbit ..."
unifi_rate() {
    tc class show dev "$WAN_IF" | awk '
        $2=="htb" && $4=="root" {
            for (i=1; i<=NF; i++) if ($i=="rate") { print $(i+1); exit }
        }'
}

# Swap UniFi's upload shaper for CAKE at the same rate.
convert_upload() {
    local rate
    rate="$(unifi_rate)"
    # Refuse to act on anything that does not look like a rate (e.g. 50Mbit).
    if ! [[ "$rate" =~ ^[0-9]+(\.[0-9]+)?[KMG]?bit$ ]]; then
        log "could not read upload rate (got '$rate'), leaving UniFi shaper alone"
        return 1
    fi
    if tc qdisc replace dev "$WAN_IF" root cake bandwidth "$rate" $CAKE_OPTS; then
        log "upload now shaped by CAKE at $rate"
    else
        log "failed to apply CAKE, UniFi shaper left in place"
        return 1
    fi
}

while true; do
    case "$(root_kind)" in
        htb)  convert_upload ;;   # UniFi just (re)applied its shaper
        cake) : ;;                # already converted, nothing to do
        *)    : ;;                # Smart Queues off in the GUI, do nothing
    esac
    sleep "$CHECK_EVERY"
done
EOF

cat << 'EOF' > /data/cake-upload/cake-upload.service
[Unit]
Description=CAKE upload shaping for WAN1 (rate read from UniFi Smart Queues)
After=network-online.target

[Service]
Type=simple
ExecStart=/bin/bash /data/cake-upload/cake-upload.sh
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF

bash -n /data/cake-upload/cake-upload.sh && \
cp /data/cake-upload/cake-upload.service /etc/systemd/system/ && \
systemctl daemon-reload && systemctl enable --now cake-upload
```

Notes on the design:

- **A loop, not a timer.** One long-running service that sleeps 60 seconds between checks writes nothing to the journal unless it changes something. A systemd timer would log a start and finish line every minute.
- **`/bin/bash` in `ExecStart`.** This runs the script without relying on execute permission under `/data`.
- **Same logic as the original install.** The script first installed on the tested unit also removed download shaping. That was switched off afterwards with `sed`, leaving an unused function in the file. The version above is the same behaviour with that function taken out. Running this install block over the top replaces it cleanly.

## UCG Ultra: verify, test and tune

The install is working when CAKE is the root queue on the WAN port, the download redirect is still present, and the log shows one conversion line.

**1. Check the log:**

```bash
journalctl -t cake-upload
```

Expected: `upload now shaped by CAKE at 50Mbit` (your rate).

**2. Check both directions:**

```bash
tc qdisc show dev eth4 | grep -E 'cake|ingress'
tc filter show dev eth4 parent ffff: | grep -i redirect
tc qdisc show dev ifbeth4
```

Expected, as seen on the tested unit:

```
qdisc cake 8003: root refcnt 5 bandwidth 50Mbit diffserv3 triple-isolate nat nowash no-ack-filter split-gso rtt 100ms noatm overhead 38 mpu 84
qdisc ingress ffff: parent ffff:fff1 ----------------
        action order 2: mirred (Egress Redirect to device ifbeth4) stolen
qdisc htb 1: root refcnt 2 r2q 10 default 0x2 direct_packets_stat 0 direct_qlen 1000
qdisc fq_codel 2: parent 1:2 limit 2000p flows 1024 quantum 1514 target 5ms interval 100ms memory_limit 4Mb ecn drop_batch 64
qdisc fq_codel 4: parent 1:4 limit 2000p flows 1024 quantum 1514 target 5ms interval 100ms memory_limit 4Mb ecn drop_batch 64
```

**3. Test the GUI link.** Change the upload figure in the GUI and apply. Within a minute the CAKE line should show the new bandwidth and a higher handle number (`8003:` became `8004:` in testing), and the log gains a line.

**4. Set the real rates.** The script uses the GUI figure as is.

- Run a speed test and note the measured upload and download.
- Set each GUI figure to roughly 90 to 95% of the measured value. That range is the usual rule of thumb for shapers, not something measured on this unit.
- A limit above what the line delivers means the shaper never becomes the bottleneck. The queue then builds at the ISP's rate limiter, where nothing manages it, and you get no latency benefit.

**5. Run the bufferbloat test again** and compare with the baseline.

**6. Confirm traffic is flowing through the download shaper.** Run this twice a few seconds apart during a download. The packet counts should climb:

```bash
tc -s qdisc show dev ifbeth4 | grep -A1 htb
```

### Still to confirm on the tested unit

These had not been done when this was written:

- [ ] Reboot once, then repeat steps 1 and 2.
- [ ] Record bufferbloat results before and after.
- [ ] Watch gateway CPU for a few days. Before the change, daily means were 24 to 37% with peaks of 97 to 100%.
- [ ] Check behaviour across a WAN failover event.
- [ ] Check the service after the next firmware update.

## Persistence, firmware updates and uninstall

The service is enabled in systemd, so it should start at every boot and convert the shaper UniFi builds. Neither a reboot nor a firmware update had been tested on this unit at the time of writing.

**What lives where**

| Path | What it is |
| --- | --- |
| `/data/cake-upload/cake-upload.sh` | The script |
| `/data/cake-upload/cake-upload.service` | Spare copy of the service unit |
| `/etc/systemd/system/cake-upload.service` | The unit systemd runs |

**Firmware updates.** One community guide, the [bufferbloat-lab UniFi chapter](https://github.com/filip-lebiecki/bufferbloat-lab/blob/main/docs/03-unifi.md), states that `/data` and `/etc` both survive firmware updates on UniFi OS. That has not been checked here. If the service is missing after an update, the spare copy in `/data` puts it back:

```bash
cp /data/cake-upload/cake-upload.service /etc/systemd/system/ && \
systemctl daemon-reload && systemctl enable --now cake-upload
```

The same guide warns that this kind of change can break on any firmware release. After each update, run the verify steps.

**Uninstall**

```bash
systemctl disable --now cake-upload
rm -f /etc/systemd/system/cake-upload.service
rm -rf /data/cake-upload
systemctl daemon-reload
```

Then re-apply the WAN settings in the GUI, or reboot, so UniFi rebuilds its stock upload shaper.
## UDM Pro: adaptation (untested)

The same script should work on a UDM Pro with one variable changed, provided two checks pass: CAKE has to be usable from the stock `tc`, and Smart Queues has to build the same HTB layout. Nothing in this section has been run on a UDM Pro.

### What differs

|  | UCG Ultra (tested) | UDM Pro (from community reports, verify on yours) |
| --- | --- | --- |
| WAN interface | `eth4` | Usually `eth8` for the RJ45 WAN port; `ppp0` on PPPoE ([bufferbloat-lab](https://github.com/filip-lebiecki/bufferbloat-lab/blob/main/docs/03-unifi.md), [ataraxia.fyi](https://www.ataraxia.fyi/home/removing-smart-queue-on-unifi)) |
| Kernel | 5.4.213 | 4.19.152 as of firmware 1.10 in 2021 ([udm-kernel releases](https://github.com/fabianishere/udm-kernel/releases)). Current firmware not checked. |
| CAKE | Module and `tc` both work | Uncertain. This is the main risk, see below. |
| Smart Queues layout | HTB root class `1:1` carries the rate | Not confirmed. An ingress hook on the WAN port is reported, as on the Ultra. |
| Service manager | systemd | systemd on UniFi OS 2.0 and later. Firmware 1.x ran UniFi OS in a container and needs a different approach. |

### The CAKE risk

CAKE needs two things: the kernel module, and a `tc` binary new enough to configure it. On the UDM Pro these have not always come together.

- A 2021 [udm-kernel-tools issue](https://github.com/fabianishere/udm-kernel-tools/issues/21) shows `modprobe sch_cake` succeeding on a UDM Pro while `tc` answered `Unknown qdisc "cake"`. The maintainer pointed at the installed iproute2 (4.9.0), which predates CAKE support. That was firmware 1.10 with a custom kernel, so it may not reflect current firmware.
- The bufferbloat-lab guide says whether `sch_cake` is compiled in varies by model and firmware.

So test before anything else.

### Procedure

**1. Test CAKE.** `lo` is used here because a `dummy0` interface may not exist on the UDM Pro. The queue is removed again straight away:

```bash
uname -r
modprobe sch_cake; lsmod | grep cake
tc qdisc replace dev lo root cake && tc qdisc show dev lo
tc qdisc del dev lo root
```

| Result | Meaning | What to do |
| --- | --- | --- |
| `qdisc cake ...` is printed | Module and `tc` both support CAKE | Carry on |
| Module loads, `tc` says `Unknown qdisc` | The `tc` binary is too old | Stop. Fixing it means installing a newer iproute2 on the gateway, which is a bigger change than this guide covers. |
| `modprobe` fails | No CAKE module in this firmware | Stop. The only route is a custom kernel, which is not sensible on a production gateway. |

**2. Find the WAN interface and confirm the layout.** Smart Queues must be on in the GUI first:

```bash
ip -br addr | grep -E 'eth|ppp'
tc qdisc show dev eth8
tc class show dev eth8 | grep root
tc filter show dev eth8 parent ffff:
```

Swap `eth8` for whichever interface holds your ISP address. You need a `qdisc htb ... root` line and a `class htb ... root rate <your upload>` line. If the rate is not on an HTB root class, the script will not find it. It logs that and leaves the stock shaper alone.

**3. Install.** Use the UCG Ultra install block with the interface changed. Paste everything except the last three lines (the `bash -n` line onwards), then run:

```bash
sed -i 's/^WAN_IF="eth4"/WAN_IF="eth8"/' /data/cake-upload/cake-upload.sh
grep '^WAN_IF' /data/cake-upload/cake-upload.sh

bash -n /data/cake-upload/cake-upload.sh && \
cp /data/cake-upload/cake-upload.service /etc/systemd/system/ && \
systemctl daemon-reload && systemctl enable --now cake-upload
```

**4. Verify** with the UCG Ultra verify steps, using your interface names. The companion download device may be named differently, so list it with `ip -br link | grep ifb`.

### PPPoE

On PPPoE, shape `ppp0` and not the physical port, because the physical port only sees tunnelled frames and CAKE cannot tell flows or devices apart there.

- Set `WAN_IF="ppp0"` and run the layout check against `ppp0`.
- Change `CAKE_OPTS`. The `ethernet` keyword assumes plain Ethernet framing, and PPPoE adds its own header. Start with `CAKE_OPTS="nat"` and a slightly lower rate, then pick the right overhead keyword from the `tc-cake` man page for your access type.
- `ppp0` disappears and returns when the session reconnects. The script copes with that, since it re-checks every minute.

### Worth knowing

The ataraxia.fyi write-up reports that Smart Queues caps a UDM Pro at about 600 Mbps and cannot be enabled for upload alone from the controller. That matches the 1 Mbps download minimum seen on the Ultra. It is one person's report and the post gives no clear date.

## Known limits and troubleshooting

### Limits

- **Unsupported.** Ubiquiti can change the Smart Queues layout in any firmware release. If the HTB root class moves or is renamed, the script stops converting and logs why. Stock shaping carries on.
- **UniFi's priority lane is replaced.** The stock upload shaper has a small high-priority class (`1:4`). CAKE uses its own three-tier scheme based on each packet's DSCP marking. What UniFi put in that lane was not investigated.
- **Up to a minute of stock shaping.** After a boot or any change that makes UniFi rebuild its shaper, upload runs on HTB + fq_codel until the next check.
- **One WAN.** Only the interface named in `WAN_IF` is converted. A second WAN keeps stock Smart Queues.
- **Download CPU cost is unchanged.** Download still runs through UniFi's shaper, which was the suspected cause of the gateway's daily CPU peaks.
- **Access points are out of scope.** Wi-Fi queueing happens inside the radio driver, below where CAKE attaches.

### Troubleshooting

| Symptom | Check | Fix |
| --- | --- | --- |
| No CAKE on the WAN port | `systemctl status cake-upload` and `journalctl -t cake-upload` | Service not running: use the re-enable commands. Log says it could not read the rate: Smart Queues is off, or the layout differs from the preflight. |
| CAKE shows the wrong rate | `tc qdisc show dev eth4` | Re-apply the upload figure in the GUI and wait a minute. |
| Download is not being shaped | `tc filter show dev eth4 parent ffff:` shows no `Redirect` line | Reboot, or restore the filter by hand (below). |
| Log fills with repeated conversion lines | `journalctl -t cake-upload` | UniFi is rebuilding its shaper often. Harmless, but note what triggers it. |
| Upload latency no better than before | Compare the GUI upload figure with a speed test | Lower the GUI figure to below the measured upload. |

Restoring the download redirect by hand, as UniFi builds it on the Ultra (a `connmark` action, then the redirect):

```bash
tc filter del dev eth4 parent ffff:
tc filter add dev eth4 parent ffff: protocol all u32 match u32 0 0 \
  action connmark action mirred egress redirect dev ifbeth4
```

This was needed once during setup, after an early version of the script had removed the redirect.

## Sources

- [UniFi Gateway: Smart Queues](https://help.ui.com/hc/en-us/articles/12648661321367), Ubiquiti Help Center. The 300 Mbps guidance.
- [bufferbloat-lab, chapter 3: bufferbloat on UniFi](https://github.com/filip-lebiecki/bufferbloat-lab/blob/main/docs/03-unifi.md). WAN interface names, PPPoE, persistence claims. No test date or firmware version given.
- [udm-kernel-tools issue 21](https://github.com/fabianishere/udm-kernel-tools/issues/21). CAKE module loading but `tc` refusing it on a UDM Pro, 2021.
- [udm-kernel releases](https://github.com/fabianishere/udm-kernel/releases). UDM Pro kernel versions by firmware.
- [Removing download smart queue on UniFi UDM Pro](https://www.ataraxia.fyi/home/removing-smart-queue-on-unifi), ataraxia.fyi. UDM Pro interface name and throughput report.

Everything in the UCG Ultra sections comes from commands run on the tested unit between 12 and 16 November 2026.