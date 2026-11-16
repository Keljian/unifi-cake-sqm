#!/bin/bash
# cake-download.sh
#
# What this does:
#   UniFi Smart Queues stays switched on in the GUI and remains the place
#   where the download limit is set. UniFi shapes download on a virtual
#   device (ifb<wan>, e.g. ifbeth4) that its ingress hook redirects every
#   incoming WAN packet to. Once a minute this script checks that device.
#   If it finds UniFi's own HTB + fq_codel shaper there, it:
#     1. reads the download rate UniFi configured,
#     2. replaces that shaper with CAKE at the same rate.
#   If CAKE is already in place it changes nothing.
#
# Optional, off by default: put one WireGuard client tunnel into CAKE's
# Bulk tin, so bulk downloads through it give way to everything else.
# Set WG_IF to the tunnel's interface name (wg show) to turn it on.
# It also turns on RPS for the tunnel, so decrypted traffic is spread over
# CPUs 1-3 instead of staying on the core that decrypted it. The tunnel
# resets RPS whenever it is recreated, so the script re-applies it.
#   - A mangle rule marks the tunnel's own UDP connection in conntrack.
#   - UniFi's ingress hook restores that connmark onto each download
#     packet before redirecting it to the ifb device.
#   - CAKE's fwmark option reads the low mark bits as a tin number:
#     1 = Bulk, 2 = Best Effort, 3 = Video, 4 = Voice.
#   UniFi's own priority-app mark (0x8004) sits in the same low bits and
#   lands in Voice. UniFi saves only the high mark bits (0x3ffe0000) to
#   conntrack, so the low bits used here do not collide with its routing
#   or VPN marks (checked on a UCG Ultra, firmware 6.0.17).
#
# Fail-safe: if this script stops, UniFi's stock Smart Queues comes back
# the next time UniFi applies its settings (or at the next reboot).
#
# Logs: journalctl -t cake-download   (only written when something changes)

WAN_IF="eth4"                 # WAN port (check with: ip -br addr)
IFB_IF="ifb${WAN_IF}"         # device UniFi redirects download traffic to
WG_IF=""                      # optional WireGuard client tunnel for Bulk
                              # and RPS, e.g. "wgclt2". Empty = feature off.
WG_RPS=e                      # RPS CPU mask for the tunnel (CPUs 1-3, the
                              # same mask UniFi uses on its own interfaces)
BULK_TIN=1                    # fwmark tin number for that tunnel (1 = Bulk)
TIN_MASK=0x7fff               # mark bits CAKE reads as the tin number
CAKE_OPTS="nat ethernet diffserv4 dual-dsthost ingress no-split-gso memlimit 128mb"
                              # nat           = see LAN addresses behind NAT
                              # ethernet      = frame overhead, same as upload
                              # diffserv4     = Bulk, Best Effort, Video, Voice
                              # dual-dsthost  = per-device fairness on download
                              # ingress       = count dropped packets against
                              #                 the rate (download mode)
                              # no-split-gso  = keep GRO-merged packets whole.
                              #                 A 64 KB lump is about 0.9 ms at
                              #                 570 Mbit, and splitting them is
                              #                 a large share of CAKE's CPU cost
                              # memlimit 128mb = queue memory cap, sized for
                              #                 many concurrent connections.
                              #                 A ceiling, not memory set aside.
CHECK_EVERY=60                # seconds between checks

log() { logger -t cake-download "$*"; }

# Prints the type of the root qdisc on the ifb device: htb, cake...
root_kind() {
    tc qdisc show dev "$IFB_IF" 2>/dev/null | awk '$4=="root"{print $2; exit}'
}

# Swap UniFi's download shaper for CAKE at the same rate.
convert_download() {
    local rate
    # UniFi's download rate is the ceil on its HTB root class 1:1
    rate=$(tc class show dev "$IFB_IF" classid 1:1 2>/dev/null |
           awk '{for (i = 1; i < NF; i++) if ($i == "ceil") {print $(i+1); exit}}')
    # Refuse to act on anything that does not look like a rate (e.g. 500Mbit).
    if ! [[ "$rate" =~ ^[0-9]+(\.[0-9]+)?[KMG]?bit$ ]]; then
        log "could not read download rate (got '$rate'), leaving UniFi shaper alone"
        return 1
    fi
    # Try with fwmark tins first; fall back without them on older kernels.
    if tc qdisc replace dev "$IFB_IF" root cake bandwidth "$rate" \
            $CAKE_OPTS fwmark "$TIN_MASK" 2>/dev/null; then
        log "download now shaped by CAKE at $rate (fwmark tins on)"
    elif tc qdisc replace dev "$IFB_IF" root cake bandwidth "$rate" $CAKE_OPTS; then
        log "download now shaped by CAKE at $rate (fwmark not supported)"
    else
        log "failed to apply CAKE, UniFi shaper left in place"
        return 1
    fi
}

# Mark the WireGuard tunnel's UDP connection so it lands in Bulk.
# UniFi rebuilds its iptables rules on provisioning, so re-add if missing.
ensure_bulk_mark() {
    [ -n "$WG_IF" ] || return 0                  # feature off
    local port
    port=$(wg show "$WG_IF" listen-port 2>/dev/null)
    [[ "$port" =~ ^[0-9]+$ ]] || return 0        # tunnel not up
    local rule=(-p udp --sport "$port" -j CONNMARK --set-xmark "$BULK_TIN/$TIN_MASK")
    if ! iptables -t mangle -C OUTPUT "${rule[@]}" 2>/dev/null; then
        iptables -t mangle -I OUTPUT 1 "${rule[@]}" &&
            log "bulk connmark rule added (udp sport $port -> tin $BULK_TIN)"
    fi
}

# Spread the tunnel's decrypted traffic across cores.
ensure_wg_rps() {
    [ -n "$WG_IF" ] || return 0                  # feature off
    local f=/sys/class/net/$WG_IF/queues/rx-0/rps_cpus
    [ -w "$f" ] || return 0                      # tunnel down
    if [ "$(cat "$f")" != "$WG_RPS" ]; then
        echo "$WG_RPS" > "$f" && log "RPS on $WG_IF set to $WG_RPS"
    fi
}

while true; do
    ensure_bulk_mark
    ensure_wg_rps
    case "$(root_kind)" in
        htb)  convert_download ;;   # UniFi just (re)applied its shaper
        cake) : ;;                  # already converted, nothing to do
        *)    : ;;                  # Smart Queues off in the GUI, do nothing
    esac
    sleep "$CHECK_EVERY"
done
