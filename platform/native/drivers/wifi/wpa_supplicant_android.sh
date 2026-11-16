#!/system/bin/sh
# wpa_supplicant + dhcpcd backend for Android-style hosts.
#
# Sourced by core/session.sh. profile.env provides:
#   NET_IFACE, NET_CTRL_DIR, NET_SERVICE, NET_DHCP_SERVICE, NET_DHCP_CMD,
#   NET_DHCP_FLAGS, NET_DRIVER_MODULE/KO/ARGS, NET_ANDROID_PROPS.
#
# The supplicant's init service and dhcpcd are the system's own tools; this
# driver only sequences them and installs the routes/DNS that netd would
# normally set up from the dhcp.<iface>.* properties.

BB="${BB:-busybox}"
if [ -n "${NET_IFACE:-}" ]; then
    NET_CTRL_SOCK="$NET_CTRL_DIR/$NET_IFACE"
else
    NET_CTRL_SOCK=""
fi
NET_DHCP_LOG="${TMP:-${NATIVE_DIR:-/data/local/tmp/t65a-native}}/dhcpcd.log"

_net_service_state() {
    getprop "init.svc.$NET_SERVICE" 2>/dev/null
}

_net_wait_service() {
    _wanted="$1"
    _i=0
    while [ $_i -lt 10 ]; do
        [ "$(_net_service_state)" = "$_wanted" ] && return 0
        sleep 1
        _i=$((_i + 1))
    done
    return 1
}

_net_has_ipv4() {
    ip -4 addr show "$NET_IFACE" 2>/dev/null | $BB grep -q "inet "
}

_net_install_routes() {
    [ "${NET_ANDROID_PROPS:-0}" = "1" ] || return 0
    GW=$(getprop "dhcp.$NET_IFACE.gateway" 2>/dev/null)
    if [ -n "$GW" ]; then
        ip route show 2>/dev/null | $BB grep -q "^default " || \
            ip route add default via "$GW" dev "$NET_IFACE" onlink 2>/dev/null
        [ -n "$(getprop net.dns1)" ] || setprop net.dns1 "$GW"
    fi
    DNS2=$(getprop "dhcp.$NET_IFACE.dns2" 2>/dev/null)
    [ -n "$DNS2" ] && setprop net.dns2 "$DNS2"
    return 0
}

_net_start_dhcp() {
    "$NET_DHCP_CMD" -k "$NET_IFACE" 2>/dev/null
    $BB setsid "$NET_DHCP_CMD" $NET_DHCP_FLAGS "$NET_IFACE" >"$NET_DHCP_LOG" 2>&1 &
}

wifi_dhcp() {
    if _net_has_ipv4; then
        _net_install_routes
        return 0
    fi
    _net_start_dhcp
    _i=0
    while [ $_i -lt 10 ]; do
        _net_has_ipv4 && break
        sleep 1
        _i=$((_i + 1))
    done
    if ! _net_has_ipv4; then
        # The first client may have raced the association; retry once.
        _net_start_dhcp
        _i=0
        while [ $_i -lt 15 ]; do
            _net_has_ipv4 && break
            sleep 1
            _i=$((_i + 1))
        done
    fi
    _net_install_routes
}

WIFI_STATE_DIR="${KO_NATIVE_DIR:-/data/local/tmp/t65a-native}"
WIFI_SDIO_SAVED="$WIFI_STATE_DIR/wifi_sdio_unbound"
WIFI_HOST_SAVED="$WIFI_STATE_DIR/wifi_host_unbound"

wifi_host_bind() {
    [ -n "${NET_SDIO_HOST_DEVICE:-}" ] && [ -f "$WIFI_HOST_SAVED" ] || return 0
    echo "$NET_SDIO_HOST_DEVICE" > \
        "/sys/bus/platform/drivers/${NET_SDIO_HOST_DRIVER:-sdhci}/bind" 2>/dev/null
    rm -f "$WIFI_HOST_SAVED"
    sleep 1
}

wifi_host_unbind() {
    [ -n "${NET_SDIO_HOST_DEVICE:-}" ] || return 0
    [ -e "/sys/bus/platform/devices/$NET_SDIO_HOST_DEVICE" ] || return 0
    echo "$NET_SDIO_HOST_DEVICE" > \
        "/sys/bus/platform/drivers/${NET_SDIO_HOST_DRIVER:-sdhci}/unbind" 2>/dev/null || return 0
    echo "$NET_SDIO_HOST_DEVICE" > "$WIFI_HOST_SAVED"
}

wifi_load() {
    # Bring the SDIO host back first (if suspend unbound it), so the card is
    # detected before the driver module is inserted.
    wifi_host_bind
    if [ -n "${NET_DRIVER_KO:-}" ] && [ ! -d "/sys/module/${NET_DRIVER_MODULE:-none}" ]; then
        # shellcheck disable=SC2086
        insmod "$NET_DRIVER_KO" $NET_DRIVER_ARGS
    fi
    # If unloading had to fall back to unbinding the SDIO functions,
    # rebind them now (if the module was not unloaded, this restores it).
    if [ -f "$WIFI_SDIO_SAVED" ]; then
        while read -r name; do
            [ -n "$name" ] || continue
            echo "$name" > /sys/bus/sdio/drivers/bcmsdh_sdmmc/bind 2>/dev/null
        done < "$WIFI_SDIO_SAVED"
        rm -f "$WIFI_SDIO_SAVED"
    fi
}

wifi_unload() {
    # bcmdhd's .suspend callback (via bcmsdh_sdmmc) re-arms the OOB IRQ wake
    # even after the interface is down, waking the system right after late
    # suspend. Unload it (or at least unbind the SDIO functions) so the PM
    # path cannot re-arm it; wifi_load restores it on resume.
    [ -n "${NET_DRIVER_MODULE:-}" ] || return 0

    # dhd_stop is asynchronous; wait for the module refcount to drop.
    i=0
    while [ $i -lt 6 ]; do
        [ -d "/sys/module/$NET_DRIVER_MODULE" ] || break
        ref=$(cat "/sys/module/$NET_DRIVER_MODULE/refcnt" 2>/dev/null)
        [ "$ref" = "0" ] && break
        sleep 1
        i=$((i+1))
    done
    if [ -d "/sys/module/$NET_DRIVER_MODULE" ]; then
        # The toolbox rmmod works; busybox rmmod silently fails on this ROM.
        /system/bin/rmmod "$NET_DRIVER_MODULE" 2>/dev/null || \
            rmmod "$NET_DRIVER_MODULE" 2>/dev/null
    fi

    # rmmod can still fail on some builds; unbind the SDIO glue as fallback
    # so its suspend callback cannot run.
    # Unbind the SDIO host controller as well: its own suspend callback
    # re-arms the card IRQ/GPIO wake even with no function driver attached.
    wifi_host_unbind

    if [ -d "/sys/module/$NET_DRIVER_MODULE" ] && [ -d /sys/bus/sdio/drivers/bcmsdh_sdmmc ]; then
        : > "$WIFI_SDIO_SAVED"
        for d in /sys/bus/sdio/devices/*; do
            [ -e "$d" ] || continue
            drv=$(sed -n 's/^DRIVER=//p' "$d/uevent" 2>/dev/null)
            [ "$drv" = "bcmsdh_sdmmc" ] || continue
            name="${d##*/}"
            echo "$name" >> "$WIFI_SDIO_SAVED"
            echo "$name" > "/sys/bus/sdio/drivers/bcmsdh_sdmmc/unbind" 2>/dev/null
        done
    fi
}

wifi_suspend() {
    # Android's "turn Wi-Fi off while asleep" path: stop the supplicant and
    # bring the interface down. The netdev stop runs bcmdhd's dhd_stop ->
    # wl_android_wifi_off -> bcmsdh_oob_intr_unregister, which removes the
    # OOB host-wake IRQ before the kernel is asked to suspend. Keep the
    # module and SDIO host loaded: rmmod/unbind re-probes the card and
    # re-arms the OOB/board wake.
    wifi_down
    # Give the supplicant teardown and the IRQ free a moment to land.
    sleep 1
}

wifi_up() {
    wifi_load

    if [ -e /dev/rfkill ]; then
        chown wifi:wifi /dev/rfkill 2>/dev/null
        chmod 660 /dev/rfkill 2>/dev/null
    fi

    ip link set "$NET_IFACE" up 2>/dev/null

    if [ -n "${NET_SERVICE:-}" ]; then
        # Always restart: a supplicant inherited from a framework session can
        # keep stale in-memory networks and loop on 4-way handshake failures.
        setprop ctl.stop "$NET_SERVICE" 2>/dev/null
        _net_wait_service stopped
        setprop ctl.start "$NET_SERVICE" 2>/dev/null
        _net_wait_service running
    fi

    _i=0
    while [ $_i -lt 10 ]; do
        [ -e "$NET_CTRL_SOCK" ] && break
        sleep 1
        _i=$((_i + 1))
    done

    _i=0
    while [ $_i -lt 15 ]; do
        [ "$(cat "/sys/class/net/$NET_IFACE/operstate" 2>/dev/null)" = "up" ] && break
        sleep 1
        _i=$((_i + 1))
    done

    wifi_dhcp
}

wifi_release() {
    "$NET_DHCP_CMD" -k "$NET_IFACE" 2>/dev/null
    return 0
}

wifi_down() {
    "$NET_DHCP_CMD" -k "$NET_IFACE" 2>/dev/null
    [ -n "${NET_SERVICE:-}" ] && setprop ctl.stop "$NET_SERVICE" 2>/dev/null
    [ -n "${NET_DHCP_SERVICE:-}" ] && setprop ctl.stop "$NET_DHCP_SERVICE" 2>/dev/null
    ip link set "$NET_IFACE" down 2>/dev/null
    return 0
}
