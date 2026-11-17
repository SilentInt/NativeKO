#!/system/bin/sh
# busybox udhcpc lease script for the Android Wi-Fi backend.
# Called as: udhcpc.sh {deconfig|bound|renew|leasefail}
# Environment: interface, ip, subnet, router, dns, lease, serverid.

IFACE="${interface:-wlan0}"

case "$1" in
    deconfig)
        ip addr flush dev "$IFACE" 2>/dev/null
        ip link set "$IFACE" up 2>/dev/null
        ;;
    bound|renew)
        ip addr flush dev "$IFACE" 2>/dev/null
        if [ -n "$ip" ] && [ -n "$subnet" ]; then
            ip addr add "$ip/$subnet" dev "$IFACE" 2>/dev/null
        fi
        if [ -n "$router" ]; then
            # udhcpc may hand out several routers; use the first.
            GW="${router%% *}"
            ip route replace default via "$GW" dev "$IFACE" 2>/dev/null
        fi
        if [ -n "$dns" ]; then
            D1="${dns%% *}"
            setprop net.dns1 "$D1" 2>/dev/null
            REST="${dns#* }"
            if [ "$REST" != "$dns" ]; then
                setprop net.dns2 "${REST%% *}" 2>/dev/null
            fi
        fi
        ;;
    leasefail)
        ;;
esac
exit 0
