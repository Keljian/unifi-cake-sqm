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
#   Download is handled separately by cake-download.sh. Without it, UniFi
#   keeps shaping download with HTB + fq_codel on the ifb device.
#
# Fail-safe: if this script stops, UniFi's stock Smart Queues comes back
# the next time UniFi applies its settings (or at the next reboot).
#
# Logs: journalctl -t cake-upload   (only written when something changes)

WAN_IF="eth4"                 # WAN port to shape (check with: ip -br addr)
CAKE_OPTS="nat ethernet diffserv4 memlimit 64mb"
                              # nat           = per-device fairness behind NAT
                              # ethernet      = Ethernet frame overhead accounting
                              # diffserv4     = four priority tins from DSCP:
                              #                 Bulk, Best Effort, Video, Voice
                              # memlimit 64mb = queue memory cap (CAKE's default
                              #                 at 50 Mbit is 4 MB). A ceiling,
                              #                 not memory set aside.
                              # Optional: append ack-filter to thin redundant TCP
                              # ACKs on upload. Untested here, see the README first.
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
