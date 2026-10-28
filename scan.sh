#!/bin/sh
# scan.sh PRESETS_ROOT [PREVIOUS_SIGNATURE]
#
# Everything service.luau needs for one refresh, gathered in a single process
# so the service's update() callback does no I/O of its own (Noctalia gives
# each callback a small time budget, which a busy system can blow through).
#
# Output: one tab-separated record per line.
#   sig     <signature> <same|new>   fingerprint of the presets tree
#   dir     <folder>                 one per preset folder
#   preset  <folder> <name>          only when the signature changed
#   input   <name> <phys> <uinput 0|1> <js 0|1>   from /proc/bus/input/devices
#   pad     <name> <eventN> <readable 0|1>        every gamepad node; 0 = hidden
#   state   <folder> <state>         input-remapper injector state (D-Bus)
#   daemon  <ok|down>
#   ds4kbm  <on|off> [preset path]
#
# Environment:
#   DS4KBM_CTL  path to ds4kbm-ctl (optional)
root=$1
previous=$2

dbus() {
    dbus-send --system --print-reply=literal --dest=inputremapper.Control \
        /inputremapper/Control "inputremapper.Control.$1" "$2" 2>/dev/null
}

# Folder and file mtimes: adding, removing, renaming or editing a preset
# changes the fingerprint, anything else leaves it alone.
sig=$({ stat -c '%n %Y' "$root" "$root"/*/ "$root"/*/*.json; } 2>/dev/null | cksum | cut -d' ' -f1)
if [ "$sig" = "$previous" ]; then
    printf 'sig\t%s\tsame\n' "$sig"
else
    printf 'sig\t%s\tnew\n' "$sig"
fi

for d in "$root"/*/; do
    [ -d "$d" ] || continue
    name=${d%/}
    name=${name##*/}
    printf 'dir\t%s\n' "$name"
    if [ "$sig" != "$previous" ]; then
        for f in "$d"*.json; do
            [ -e "$f" ] || continue
            p=${f##*/}
            printf 'preset\t%s\t%s\n' "$name" "${p%.json}"
        done
    fi
done

awk -v OFS='\t' '
    function flush() { if (n != "") print "input", n, p, u + 0, j + 0; n = ""; p = ""; u = 0; j = 0 }
    /^N: Name=/   { n = $0; sub(/^N: Name="/, "", n); sub(/"[[:space:]]*$/, "", n) }
    /^P: Phys=/   { p = substr($0, 9) }
    /^S: Sysfs=/  { u = index($0, "/devices/virtual/input/") > 0 }
    /^H: Handlers=/ { j = ($0 ~ /[= ]js[0-9]/) }
    /^$/          { flush() }
    END           { flush() }
' /proc/bus/input/devices

# Gamepad nodes and whether we may open them: noctalia-padhide makes a
# controller root-only while input-remapper runs it.
for js in /sys/class/input/js*; do
    [ -e "$js/device/name" ] || continue
    IFS= read -r name <"$js/device/name"
    for ev in "$js"/device/event*; do
        [ -e "$ev" ] || continue
        node=${ev##*/}
        if [ -r "/dev/input/$node" ]; then readable=1; else readable=0; fi
        printf 'pad\t%s\t%s\t%s\n' "$name" "$node" "$readable"
    done
done

if dbus hello string:scan >/dev/null; then
    printf 'daemon\tok\n'
    for d in "$root"/*/; do
        [ -d "$d" ] || continue
        name=${d%/}
        name=${name##*/}
        state=$(dbus get_state "string:$name") || state=ERR
        printf 'state\t%s\t%s\n' "$name" $state
    done
else
    printf 'daemon\tdown\n'
fi

if [ -n "$DS4KBM_CTL" ] && out=$("$DS4KBM_CTL" status); then
    printf 'ds4kbm\ton\t%s\n' "$(printf '%s\n' "$out" | sed -n 2p)"
else
    printf 'ds4kbm\toff\n'
fi
