#!/usr/bin/env python3
"""Generate the two runtime views of a device profile from profile.json.

  profile.env  -> sourced by core/session.sh and the host/wifi drivers
  profile.lua  -> loaded by the KOReader side (device/native/device.lua)

A single JSON file is the source of truth, so shell and Lua cannot drift.

Usage: profilegen.py PROFILE.json OUTPUT_DIR
"""

import json
import os
import sys


def lua_str(s):
    out = ['"']
    for ch in s:
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        elif ch == "\t":
            out.append("\\t")
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def lua_val(v, indent=0):
    pad = "  " * indent
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, str):
        return lua_str(v)
    if isinstance(v, list):
        if not v:
            return "{}"
        inner = ", ".join(lua_val(x, indent + 1) for x in v)
        return "{ " + inner + " }"
    if isinstance(v, dict):
        if not v:
            return "{}"
        lines = ["{"]
        for k, val in v.items():
            lines.append("%s  [%s] = %s," % (pad, lua_str(k), lua_val(val, indent + 1)))
        lines.append(pad + "}")
        return "\n".join(lines)
    raise TypeError("unsupported type: %r" % (v,))


def sh_quote(s):
    return "'" + str(s).replace("'", "'\\''") + "'"


def join_list(items):
    return " ".join(str(x) for x in items)


def main():
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    src, outdir = sys.argv[1], sys.argv[2]
    with open(src, "r", encoding="utf-8") as f:
        p = json.load(f)

    os.makedirs(outdir, exist_ok=True)

    disp = p.get("display", {})
    inp = p.get("input", {})
    power = p.get("power", {})
    net = p.get("network", {})
    host = p.get("host", {})
    paths = p.get("paths", {})
    tools = p.get("tools", {})
    match = p.get("match", {})

    keys = []
    for k, v in inp.get("keys", {}).items():
        keys.append("%s:%s" % (k, v))

    env = {
        "PROFILE_ID": p.get("id", "unknown"),
        "PROFILE_MODEL": p.get("model", ""),
        "MATCH_PRODUCT": match.get("product", ""),
        "MATCH_BRAND": match.get("brand", ""),

        "DISP_FB": disp.get("fb", ""),
        "DISP_BLANK": disp.get("blank", ""),
        "DISP_PAN": disp.get("pan", ""),
        "DISP_PAN_VALUE": disp.get("pan_value", ""),
        "DISP_BACKEND": disp.get("backend", ""),
        "DISP_PORTRAIT": "1" if disp.get("portrait") else "0",
        "DISP_TOUCH_ROTATION": disp.get("touch_rotation", 0),
        "DISP_DPI": disp.get("dpi", 0),

        "INPUT_DEVICES": join_list(inp.get("devices", [])),
        "INPUT_KEYS": join_list(keys),
        "INPUT_QUIRKS": join_list(inp.get("quirks", [])),

        "PWR_BATTERY_CAPACITY": power.get("battery_capacity", ""),
        "PWR_BATTERY_STATUS": power.get("battery_status", ""),
        "PWR_FRONT_LIGHT": power.get("frontlight", ""),
        "PWR_FL_MIN": power.get("fl_min", 0),
        "PWR_FL_MAX": power.get("fl_max", 100),
        "PWR_MODEL": power.get("model", power.get("suspend", "")),
        "PWR_WAKEUP_DISABLE": join_list(power.get("wakeup_disable", [])),
        "PWR_WAKE_UNLOCK": join_list(power.get("wake_unlock", [])),
        "PWR_WAKE_LOCK_NAME": power.get("wake_lock_name", ""),
        "PWR_RTC_ALARM": power.get("rtc_alarm", ""),
        "PWR_SUSPEND_STATE": power.get("suspend_state", "mem"),
        "PWR_SUSPEND_FALLBACK": power.get("suspend_fallback", "standby"),

        "NET_MANAGE": "1" if net.get("manage") else "0",
        "NET_START_ON_BOOT": "1" if net.get("start_on_boot") else "0",
        "NET_IFACE": net.get("iface", ""),
        "NET_BACKEND": net.get("backend", ""),
        "NET_CTRL_DIR": net.get("ctrl_dir", ""),
        "NET_CTRL_INTERFACE": net.get("ctrl_interface", ""),
        "NET_WPA_GLOBAL": "1" if net.get("wpa_global") else "0",
        "NET_WPA_IFNAME": net.get("wpa_ifname", ""),
        "NET_SERVICE": net.get("service", ""),
        "NET_SERVICE_PROP": net.get("service_prop", ""),
        "NET_DHCP_SERVICE": net.get("dhcp_service", ""),
        "NET_DHCP_CMD": net.get("dhcp_cmd", "/system/bin/dhcpcd"),
        "NET_DHCP_FLAGS": net.get("dhcp_flags", ""),
        "NET_DRIVER_MODULE": net.get("driver_module", ""),
        "NET_DRIVER_KO": net.get("driver_ko", ""),
        "NET_DRIVER_ARGS": net.get("driver_args", ""),
        "NET_ANDROID_PROPS": "1" if net.get("android_props") else "0",
        "NET_SDIO_HOST_DRIVER": net.get("sdio_host_driver", ""),
        "NET_SDIO_HOST_DEVICE": net.get("sdio_host_device", ""),

        "HOST_BACKEND": host.get("backend", "none"),
        "HOST_STOP_SERVICES": join_list(host.get("stop", [])),
        "HOST_START_SERVICES": join_list(host.get("start", [])),
        "HOST_GOV_NATIVE": host.get("governor_native", "interactive"),
        "HOST_GOV_FALLBACK": host.get("governor_fallback", "conservative"),

        "TOOL_IP": tools.get("ip", "/system/bin/ip"),
        "TOOL_PING": tools.get("ping", "/system/bin/ping"),
        "TOOL_SETSID": tools.get("setsid", "setsid"),
        "TOOL_GETPROP": tools.get("getprop", "getprop"),
        "TOOL_BUSYBOX": tools.get("busybox", "busybox"),

        "DATA_DIR": paths.get("data_dir", ""),
        "HOME_DIR": paths.get("home_dir", ""),
    }

    with open(os.path.join(outdir, "profile.env"), "w", encoding="utf-8") as f:
        f.write("# Generated from %s - do not edit.\n" % os.path.basename(src))
        for k, v in env.items():
            f.write("%s=%s\n" % (k, sh_quote(v)))

    with open(os.path.join(outdir, "profile.lua"), "w", encoding="utf-8") as f:
        f.write("-- Generated from %s - do not edit.\n" % os.path.basename(src))
        f.write("return " + lua_val(p) + "\n")

    return 0


if __name__ == "__main__":
    sys.exit(main())
