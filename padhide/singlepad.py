#!/usr/bin/env python3
"""Does a preset leave the controller's forwarded copy silent?

usage: singlepad.py analyze DIR      {preset: {"full": bool, "missing": n}} as JSON
       singlepad.py copy PRESET      write "<name> Single Pad.json" next to it

input-remapper hands every event that no mapping takes to a "forwarded" copy
of the controller. A preset that maps only some buttons therefore splits the
controller over two virtual pads: its gamepad output on one, the rest on the
forwarded copy. A preset is "full" when every button and axis the controller
has is the input of a single-input mapping, so the forwarded copy never says
anything and can be hidden from games together with the original.

`copy` makes a full preset out of a partial one: every unmapped button and
axis is added as a 1:1 mapping to input-remapper's gamepad (axes without an
extra deadzone, the game has its own). The original is not touched.

The controller is identified by the preset folder's name, which is its
device name, and has to be connected (its buttons and axes are read from
sysfs). Without it, `analyze` prints {} and `copy` fails.
"""
import json
import os
import sys

EV_KEY, EV_ABS = 1, 3


def bits(path):
    """Set bit numbers of a sysfs capability bitmap (hex words, high first)."""
    with open(path) as f:
        words = f.read().split()
    out = []
    for i, word in enumerate(reversed(words)):
        value = int(word, 16)
        for bit in range(64):
            if value >> bit & 1:
                out.append(i * 64 + bit)
    return out


def capabilities(device):
    """{EV_KEY: [...], EV_ABS: [...]} of the real controller, or None."""
    for entry in sorted(os.listdir("/sys/class/input")):
        if not entry.startswith("event"):
            continue
        dev = f"/sys/class/input/{entry}/device"
        try:
            with open(f"{dev}/name") as f:
                if f.read().rstrip("\n") != device:
                    continue
            with open(f"{dev}/phys") as f:
                if f.read().strip() in ("input-remapper", "ds4kbm"):
                    continue
            if not any(e.startswith("js") for e in os.listdir(dev)):
                continue
            # Buttons only: the key bitmap of a gamepad starts at BTN_MISC.
            keys = [c for c in bits(f"{dev}/capabilities/key") if c >= 0x100]
            return {EV_KEY: keys, EV_ABS: bits(f"{dev}/capabilities/abs")}
        except OSError:
            continue
    return None


def load(path):
    with open(path) as f:
        mappings = json.load(f)
    if not isinstance(mappings, list):
        raise ValueError("not an input-remapper 2 preset")
    return mappings


def covered(mappings):
    """(type, code) pairs taken by a single-input mapping."""
    out = set()
    for m in mappings:
        combo = m.get("input_combination") or []
        if len(combo) == 1:
            out.add((combo[0].get("type"), combo[0].get("code")))
    return out


def missing(mappings, caps):
    have = covered(mappings)
    return [(t, c) for t in (EV_KEY, EV_ABS) for c in caps[t] if (t, c) not in have]


def analyze(directory):
    caps = capabilities(os.path.basename(os.path.normpath(directory)))
    if caps is None:
        return {}
    result = {}
    for file in sorted(os.listdir(directory)):
        if not file.endswith(".json"):
            continue
        try:
            gap = missing(load(os.path.join(directory, file)), caps)
            result[file[:-5]] = {"full": not gap, "missing": len(gap)}
        except (OSError, ValueError, AttributeError, TypeError):
            continue
    return result


def copy(preset):
    preset = os.path.realpath(preset)
    directory = os.path.dirname(preset)
    caps = capabilities(os.path.basename(directory))
    if caps is None:
        sys.exit("the controller is not connected")
    mappings = load(preset)
    origin = next(
        (i.get("origin_hash") for m in mappings for i in m.get("input_combination") or []
         if i.get("origin_hash")),
        None,
    )
    if origin is None:
        sys.exit("the preset has no mapping to take the controller's id from")

    added = list(mappings)
    for type_, code in missing(mappings, caps):
        entry = {
            "input_combination": [{"type": type_, "code": code, "origin_hash": origin}],
            "target_uinput": "gamepad",
            "output_type": type_,
            "output_code": code,
        }
        if type_ == EV_ABS:
            entry.update(mapping_type="analog", deadzone=0.0)
        else:
            entry.update(mapping_type="key_macro")
        added.append(entry)

    base = os.path.basename(preset)[:-5] + " Single Pad"
    name, n = base, 2
    while os.path.exists(os.path.join(directory, name + ".json")):
        name, n = f"{base} {n}", n + 1
    with open(os.path.join(directory, name + ".json"), "x") as f:
        json.dump(added, f, indent=4)
    print(name)


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("analyze", "copy"):
        sys.exit(__doc__)
    if sys.argv[1] == "analyze":
        print(json.dumps(analyze(sys.argv[2])))
    else:
        copy(sys.argv[2])


if __name__ == "__main__":
    main()
