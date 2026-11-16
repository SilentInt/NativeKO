#!/system/bin/sh
# Collect the hardware/software facts needed to port NativeKO to a Rockchip
# (or other) e-ink device.  Run as root on the device:
#
#   adb push platform/native/tools/rk-ebc-env.sh /data/local/tmp/
#   adb shell su -c 'sh /data/local/tmp/rk-ebc-env.sh'
#
# This script is read-only.  For EBC buffer/refresh probing, build and run
# platform/native/tools/rk-ebc-probe.c (see RK_EBC.md).

echo "== build =="
getprop ro.product.model
getprop ro.product.device
getprop ro.product.manufacturer
getprop ro.build.version.release
getprop ro.build.version.sdk
getprop ro.product.cpu.abi
getprop ro.build.fingerprint

echo "== kernel =="
cat /proc/version
cat /proc/cmdline 2>/dev/null

echo "== cpu =="
grep -E 'model name|CPU part|Features|Hardware|processor' /proc/cpuinfo | head -20

echo "== display =="
ls -l /dev/ebc /dev/graphics/fb0 /dev/fb0 2>&1
grep -iE 'ebc|epd|fb' /proc/misc 2>/dev/null
for f in name virtual_size stride bits_per_pixel rotate screen_info pan state \
         phys_addr modes mode; do
    p=/sys/class/graphics/fb0/$f
    [ -f "$p" ] && echo "$f=$(cat "$p" 2>/dev/null)"
done
ls /sys/class/graphics

echo "== input =="
cat /proc/bus/input/devices
ls -l /dev/input

echo "== power/backlight =="
ls /sys/class/backlight 2>/dev/null
for d in /sys/class/backlight/*; do
    [ -e "$d" ] || continue
    echo "$d max=$(cat "$d/max_brightness" 2>/dev/null) cur=$(cat "$d/brightness" 2>/dev/null)"
done
ls /sys/class/power_supply
for d in /sys/class/power_supply/*; do
    [ -e "$d" ] || continue
    echo "$(basename "$d") type=$(cat "$d/type" 2>/dev/null) cap=$(cat "$d/capacity" 2>/dev/null)"
done

echo "== network =="
ls /sys/class/net
getprop wifi.interface
getprop | grep -E 'init.svc.(wpa_supplicant|dhcpcd)' | head
ls /data/misc/wifi/sockets 2>/dev/null

echo "== services =="
getprop | grep -E 'init.svc.(zygote|surfaceflinger|media|drm|installd|keystore)' | head
ps 2>/dev/null | grep -E 'zygote|surfaceflinger|system_server' | head

echo "== tools =="
for t in ip ping setsid getprop dmesg getevent fbset busybox toybox; do
    echo -n "$t: "; which "$t" 2>/dev/null || echo none
done

echo "== notes =="
echo "For RK EBC devices, build rk-ebc-probe and run 'info'/'hist', then stop"
echo "SurfaceFlinger and calibrate bpp/stride/orientation with pattern/corner."
echo "See platform/native/RK_EBC.md."
