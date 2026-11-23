#!/system/bin/sh
# wpa_supplicant + dhcpcd backend for Android-style hosts.
#
# Sourced by core/session.sh. profile.env provides:
#   NET_IFACE, NET_CTRL_DIR, NET_CTRL_INTERFACE, NET_SERVICE, NET_DHCP_SERVICE,
#   NET_DHCP_CMD, NET_DHCP_FLAGS, NET_DRIVER_MODULE/KO/ARGS, NET_ANDROID_PROPS.
#
# The supplicant's init service and dhcpcd are the system's own tools; this
# driver only sequences them and installs the routes/DNS that netd would
# normally set up from the dhcp.<iface>.* properties.

BB="${BB:-busybox}"
if [ -n "${NET_IFACE:-}" ]; then
    # Android's init services often expose only a global supplicant socket
    # (-g@android:wpa_wlan0), not <ctrl_dir>/<iface>.
    NET_CTRL_SOCK="${NET_CTRL_INTERFACE:-$NET_CTRL_DIR/$NET_IFACE}"
else
    NET_CTRL_SOCK=""
fi
NET_DHCP_LOG="${TMP:-${NATIVE_DIR:-/data/local/tmp/nativeko}}/dhcpcd.log"
NET_DHCP_KIND="${NET_DHCP_KIND:-dhcpcd}"
NET_DHCP_BUSYBOX="${NET_DHCP_BUSYBOX:-}"
NET_SELINUX_ALLOW="${NET_SELINUX_ALLOW:-}"

# Apply profile-supplied SELinux allow rules (pipe-separated).  e.g. Android 8
# wpa_supplicant is in hal_wifi_supplicant_default and cannot send replies to
# a root/magisk wpa_ctrl client without this targeted rule.
_net_selinux_allow() {
    [ -n "$NET_SELINUX_ALLOW" ] || return 0
    command -v magiskpolicy >/dev/null 2>&1 || return 0
    _old_ifs="$IFS"
    IFS='|'
    for _rule in $NET_SELINUX_ALLOW; do
        [ -n "$_rule" ] || continue
        if magiskpolicy --live "$_rule" 2>/dev/null; then
            echo "selinux_allow: $_rule" >>"$NET_DHCP_LOG"
        fi
    done
    IFS="$_old_ifs"
    return 0
}

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

# Resolve the default gateway.  Prefer the dhcp.<iface>.gateway property set by
# the ROM's dhcpcd hooks; some Android 6 builds never set it (the hooks fail or
# are disabled), so fall back to the interface address's .1 and then the ARP
# table.
_net_gateway() {
    _gw=$(getprop "dhcp.$NET_IFACE.gateway" 2>/dev/null)
    if [ -n "$_gw" ]; then
        echo "$_gw"
        return 0
    fi
    _addr=$(ip -4 addr show "$NET_IFACE" 2>/dev/null | \
        $BB sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | $BB head -1)
    if [ -n "$_addr" ]; then
        echo "${_addr%.*}.1"
        return 0
    fi
    ip neigh 2>/dev/null | \
        $BB sed -n "s/^\([0-9.]*\) dev $NET_IFACE .*/\1/p" | $BB head -1
}

_net_dns1() {
    _dns=$(getprop "dhcp.$NET_IFACE.dns1" 2>/dev/null)
    if [ -n "$_dns" ]; then
        echo "$_dns"
    else
        _net_gateway
    fi
}

_net_install_routes() {
    [ "${NET_ANDROID_PROPS:-0}" = "1" ] || return 0
    GW=$(_net_gateway)
    if [ -n "$GW" ]; then
        ip route show 2>/dev/null | $BB grep -q "^default " || \
            ip route add default via "$GW" dev "$NET_IFACE" onlink 2>/dev/null
        if [ -z "$(getprop net.dns1)" ]; then
            DNS1=$(_net_dns1)
            [ -n "$DNS1" ] && setprop net.dns1 "$DNS1"
        fi
    fi
    DNS2=$(getprop "dhcp.$NET_IFACE.dns2" 2>/dev/null)
    [ -n "$DNS2" ] && setprop net.dns2 "$DNS2"
    return 0
}

_net_release_dhcp() {
    if [ "$NET_DHCP_KIND" = "udhcpc" ]; then
        if [ -n "$NET_DHCP_BUSYBOX" ]; then
            "$NET_DHCP_BUSYBOX" pkill -f "udhcpc -i $NET_IFACE" 2>/dev/null
        fi
        ip addr flush dev "$NET_IFACE" 2>/dev/null
        ip route del default dev "$NET_IFACE" 2>/dev/null
        return 0
    fi
    [ -n "$NET_DHCP_CMD" ] && "$NET_DHCP_CMD" -k "$NET_IFACE" 2>/dev/null
    return 0
}

_net_start_dhcp() {
    _net_release_dhcp
    if [ "$NET_DHCP_KIND" = "udhcpc" ]; then
        if [ -z "$NET_DHCP_BUSYBOX" ]; then
            echo "wifi: udhcpc requested but dhcp_busybox is empty" \
                >>"$NET_DHCP_LOG"
            return 1
        fi
        # Foreground, one-shot lease.  The init service may have left the
        # interface without an address; udhcpc writes it through its script.
        "$NET_DHCP_BUSYBOX" udhcpc -i "$NET_IFACE" \
            -s "$NATIVE_DIR/drivers/wifi/udhcpc.sh" \
            -f -q -n -t 5 -T 3 >>"$NET_DHCP_LOG" 2>&1
        return $?
    fi
    $BB setsid "$NET_DHCP_CMD" $NET_DHCP_FLAGS "$NET_IFACE" >>"$NET_DHCP_LOG" 2>&1 &
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

WIFI_STATE_DIR="${KO_NATIVE_DIR:-/data/local/tmp/nativeko}"
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
    # Built-in bcmdhd has a /sys/module entry but no refcnt; skip the
    # pointless wait and rmmod in that case.
    if [ -e "/sys/module/$NET_DRIVER_MODULE/refcnt" ]; then
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
    # bring the interface down.  Profiles with a fragile SDIO/bcmdhd stack
    # can additionally unbind the SDIO functions and host controller so the
    # driver is re-probed cleanly on resume instead of calling dhd_open on a
    # stale card state.
    wifi_down
    if [ "${NET_SUSPEND_UNLOAD:-0}" = "1" ]; then
        wifi_unload
    fi
    # Give the supplicant teardown and the IRQ free a moment to land.
    sleep 1
}

wifi_up() {
    _net_selinux_allow
    wifi_load

    if [ -e /dev/rfkill ]; then
        chown wifi:wifi /dev/rfkill 2>/dev/null
        chmod 660 /dev/rfkill 2>/dev/null
    fi

    ip link set "$NET_IFACE" up 2>/dev/null

    if [ -n "${NET_SERVICE:-}" ]; then
        # A resume/restore can race the startup wifi_up.  Restarting an
        # already running supplicant drops a just-established association;
        # only force a restart at session start (WIFI_FORCE_RESTART=1).
        svc_state=$(getprop "init.svc.$NET_SERVICE" 2>/dev/null)
        if [ "${WIFI_FORCE_RESTART:-0}" = "1" ] || [ "$svc_state" != "running" ]; then
            setprop ctl.stop "$NET_SERVICE" 2>/dev/null
            _net_wait_service stopped
            setprop ctl.start "$NET_SERVICE" 2>/dev/null
            _net_wait_service running
        fi
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
    _net_release_dhcp
    return 0
}

wifi_down() {
    _net_release_dhcp
    [ -n "${NET_SERVICE:-}" ] && setprop ctl.stop "$NET_SERVICE" 2>/dev/null
    [ -n "${NET_DHCP_SERVICE:-}" ] && setprop ctl.stop "$NET_DHCP_SERVICE" 2>/dev/null
    ip link set "$NET_IFACE" down 2>/dev/null
    return 0
}
