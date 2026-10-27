#!/usr/bin/env python3
"""ds4kbm - run an input-remapper preset with a DualShock 4 shown as keyboard + mouse.

The real controller (and its touchpad / motion-sensor nodes) is grabbed
exclusively, so applications only ever see a virtual keyboard and a virtual
absolute pointer - never a gamepad. This keeps games that switch their UI on
"last input device" from flickering between gamepad and mouse modes.

  - left stick X -> cursor X (absolute), back to center when released,
                    smoothed with a One Euro filter to hide stick jitter
  - R2 / L2      -> left / right mouse button, either plain clicks or PWM
                    pulses whose duty cycle follows the trigger depth
  - everything else follows the input-remapper preset given on the command
    line. Supported: button -> key, button -> mouse button, hold_keys(...),
    and axis-with-threshold (e.g. D-pad) -> key. Other mappings are skipped
    and logged.

Output events are only written when the output actually changes.
"""
import argparse
import fcntl
import json
import math
import os
import re
import select
import signal
import sys
import time

import evdev
from evdev import AbsInfo, UInput, ecodes as e

RANGE = 32767
POINTER_BUTTONS = {e.BTN_LEFT, e.BTN_RIGHT, e.BTN_MIDDLE, e.BTN_SIDE, e.BTN_EXTRA}
KEYBOARD_TARGETS = {"keyboard", "mouse", "keyboard + mouse"}

STEER_AXIS = e.ABS_X
TRIGGER_MAP = {e.ABS_RZ: e.BTN_LEFT, e.ABS_Z: e.BTN_RIGHT}   # R2, L2
RESERVED_AXES = {STEER_AXIS: "left stick X", e.ABS_RZ: "R2", e.ABS_Z: "L2"}

EXPO = 1.0                   # stick response curve, 1.0 = linear
TRIG_DEADZONE = 8            # 0..255, below this the trigger counts as released
CLICK_ON, CLICK_OFF = 40, 20  # 0..255, hysteresis for "click" mode
PWM_FULL = 0.95              # trigger depth (0..1) above which the button is held solid

HOLD_KEYS = re.compile(r"^\s*hold_keys\s*\((.*)\)\s*$", re.S)


def log(*a):
    print(*a, file=sys.stderr, flush=True)


def run_prefix():
    """Shared with ds4kbm-ctl: $XDG_RUNTIME_DIR/ds4kbm, else /tmp/ds4kbm-<uid>."""
    xdg = os.environ.get("XDG_RUNTIME_DIR")
    return os.path.join(xdg, "ds4kbm") if xdg else f"/tmp/ds4kbm-{os.getuid()}"


def single_instance(preset_path):
    """Hold an exclusive lock on the pidfile for the life of the process.

    The pidfile carries the real pid of the instance holding the lock and the
    preset it runs, so ds4kbm-ctl can never lose track of a running instance,
    and a second instance refuses to start."""
    fd = os.open(run_prefix() + ".pid", os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        log("already running")
        sys.exit(3)
    os.ftruncate(fd, 0)
    os.write(fd, f"{os.getpid()}\n{preset_path}\n".encode())
    return fd


# ---------------------------------------------------------------------------
# input-remapper presets
# ---------------------------------------------------------------------------

def symbol_code(name):
    """evdev code for an output symbol such as "KEY_V", "BTN_RIGHT" or "v"."""
    name = name.strip()
    for candidate in (name, "KEY_" + name.upper()):
        value = e.ecodes.get(candidate)
        if isinstance(value, int):
            return value
    return None


class Mapping:
    """One usable preset entry: an input (button, or axis past a threshold)
    that holds a list of output codes down while it is active."""

    def __init__(self, name, ev_type, code, threshold, outputs):
        self.name = name
        self.ev_type = ev_type
        self.code = code
        self.threshold = threshold
        self.outputs = outputs

    def active(self, value, info=None):
        if self.ev_type == e.EV_KEY:
            return value != 0
        # axis: threshold is a percentage of the half range, its sign the direction
        mid = (info.min + info.max) / 2
        half = (info.max - info.min) / 2 or 1
        pct = (value - mid) / half * 100
        return pct >= self.threshold if self.threshold > 0 else pct <= self.threshold


def parse_entry(raw):
    """Return (Mapping, None) or (None, reason it is skipped)."""
    combo = raw.get("input_combination") or []
    if len(combo) != 1:
        return None, f"combination of {len(combo)} inputs"
    mtype = raw.get("mapping_type", "key_macro")
    if mtype != "key_macro":
        return None, f"{mtype} mapping"
    target = raw.get("target_uinput", "keyboard")
    if target not in KEYBOARD_TARGETS:
        return None, f"{target} output"

    inp = combo[0]
    ev_type, code = inp.get("type"), inp.get("code")
    threshold = inp.get("analog_threshold")
    if ev_type == e.EV_ABS:
        if code in RESERVED_AXES:
            return None, f"{RESERVED_AXES[code]} is used for the cursor / clicks"
        if not threshold:
            return None, "analog axis"
    elif ev_type != e.EV_KEY:
        return None, f"input type {ev_type}"

    symbol = (raw.get("output_symbol") or "").strip()
    m = HOLD_KEYS.match(symbol)
    names = [n for n in m.group(1).split(",") if n.strip()] if m else [symbol]
    if not m and "(" in symbol:
        return None, f"macro {symbol.split('(')[0]}()"
    outputs = []
    for n in names:
        c = symbol_code(n)
        if c is None:
            return None, f"unknown symbol {n.strip()!r}"
        if c >= e.BTN_MISC and c not in POINTER_BUTTONS and c < e.KEY_OK:
            return None, f"gamepad output {n.strip()}"
        outputs.append(c)
    if not outputs:
        return None, "no output"

    label = raw.get("name") or f"{ev_type}:{code}"
    return Mapping(label, ev_type, code, threshold or 0, outputs), None


def load_preset(path):
    """Return (mappings, skipped) where skipped is a list of (label, reason)."""
    with open(path) as f:
        raw = json.load(f)
    if isinstance(raw, dict):   # older presets wrap the list
        raw = raw.get("mappings", [])
    mappings, skipped = [], []
    for entry in raw:
        mapping, reason = parse_entry(entry)
        if mapping is None:
            skipped.append((entry.get("name") or entry.get("output_symbol") or "?", reason))
        else:
            mappings.append(mapping)
    return mappings, skipped


def analyze(directory):
    """{preset name: {"usable": n, "skipped": m}} for every preset in a folder."""
    result = {}
    for file in sorted(os.listdir(directory)):
        if not file.endswith(".json"):
            continue
        try:
            mappings, skipped = load_preset(os.path.join(directory, file))
            result[file[:-5]] = {"usable": len(mappings), "skipped": len(skipped)}
        except (OSError, ValueError, AttributeError, TypeError) as ex:
            result[file[:-5]] = {"usable": 0, "skipped": 0, "error": str(ex)}
    return result


# ---------------------------------------------------------------------------
# devices
# ---------------------------------------------------------------------------

def find_controller(device_name):
    """Return (main, [siblings]) for the real controller.

    Virtual copies made by input-remapper or by ds4kbm itself are skipped, as
    is anything not sharing the main node's HID parent.
    """
    main, sibs = None, []
    for path in evdev.list_devices():
        try:
            d = evdev.InputDevice(path)
        except OSError:
            continue
        if not d.name.startswith(device_name) or d.phys in ("input-remapper", "ds4kbm"):
            d.close()
            continue
        caps = d.capabilities()
        if d.name == device_name and STEER_AXIS in [c for c, _ in caps.get(e.EV_ABS, [])]:
            main = d
        else:
            sibs.append(d)
    if main is None:
        for d in sibs:
            d.close()
        return None, []

    def parent(dev):
        return os.path.realpath(f"/sys/class/input/{os.path.basename(dev.path)}/device/..")

    keep = []
    for d in sibs:
        if parent(d) == parent(main):
            keep.append(d)
        else:
            d.close()
    return main, keep


class OneEuro:
    """One Euro filter (Casiez et al. 2012): heavy smoothing while the input
    moves slowly (jitter), little lag while it moves fast (a quick flick)."""

    D_CUTOFF = 1.0

    def __init__(self, min_cutoff, beta):
        self.min_cutoff = min_cutoff
        self.beta = beta
        self.x = None
        self.dx = 0.0
        self.t = None

    @staticmethod
    def _alpha(cutoff, dt):
        tau = 1.0 / (2 * math.pi * cutoff)
        return 1.0 / (1.0 + tau / dt)

    def __call__(self, x, t):
        if self.x is None:
            self.x, self.t = x, t
            return x
        dt = t - self.t
        if dt <= 0:
            return self.x
        self.t = t
        a_d = self._alpha(self.D_CUTOFF, dt)
        self.dx = a_d * (x - self.x) / dt + (1 - a_d) * self.dx
        cutoff = self.min_cutoff + self.beta * abs(self.dx)
        a = self._alpha(cutoff, dt)
        self.x = a * x + (1 - a) * self.x
        return self.x


class Output:
    def __init__(self, args, mappings):
        self.args = args
        keys = {c for m in mappings for c in m.outputs if c not in POINTER_BUTTONS}
        self.kbd = UInput({e.EV_KEY: sorted(keys) or [e.KEY_ESC]}, name="ds4kbm keyboard", phys="ds4kbm")
        self.ptr = UInput({
            e.EV_KEY: sorted(POINTER_BUTTONS),
            e.EV_ABS: [
                (e.ABS_X, AbsInfo(0, 0, RANGE, 0, 0, 0)),
                (e.ABS_Y, AbsInfo(0, 0, RANGE, 0, 0, 0)),
            ],
        }, name="ds4kbm pointer", phys="ds4kbm")
        self.held = {}   # output code -> set of inputs holding it down
        self.x = None
        self.target = 0.0
        self.reset_filter()
        self.trig = {c: 0 for c in TRIGGER_MAP}       # current depth 0..255
        self.trig_on = {c: False for c in TRIGGER_MAP}

    def reset_filter(self):
        self.filter = OneEuro(self.args.min_cutoff, self.args.beta) if self.args.smoothing else None

    def key(self, code, val, src):
        """Press/release `code` on behalf of input `src`. Several inputs may
        share one output (e.g. R1 and L2 both braking); it stays down while
        any of them holds it."""
        srcs = self.held.setdefault(code, set())
        was = bool(srcs)
        (srcs.add if val else srcs.discard)(src)
        if bool(srcs) == was:
            return
        dev = self.ptr if code in POINTER_BUTTONS else self.kbd
        dev.write(e.EV_KEY, code, 1 if srcs else 0)
        dev.syn()

    def mapping(self, m, on):
        # hold_keys semantics: press in order, release in reverse
        for code in (m.outputs if on else reversed(m.outputs)):
            self.key(code, on, ("map", id(m)))

    def steer(self, n):
        self.target = n
        return self.steer_tick()

    def steer_tick(self):
        """Advance the filter; returns the select() timeout until the next tick."""
        if self.filter is None:
            self.move(self.target)
            return None
        n = self.filter(self.target, time.monotonic())
        self.move(n)
        # keep ticking until the output has settled on the target
        if self.pos(n) != self.pos(self.target):
            return 0.008
        return None

    def pos(self, n):
        return max(0, min(RANGE, round(RANGE / 2 * (1 + n * self.args.scale))))

    def move(self, n):
        x = self.pos(n)
        if x == self.x:
            return
        first = self.x is None
        self.x = x
        self.ptr.write(e.EV_ABS, e.ABS_X, x)
        if first:
            self.ptr.write(e.EV_ABS, e.ABS_Y, round(self.args.cursor_y * RANGE))
        self.ptr.syn()

    def trigger(self, code, value):
        if value < TRIG_DEADZONE:
            value = 0
        if self.args.trigger_mode == "pwm":
            self.trig[code] = value
            self.pwm_tick()
        else:
            on = self.trig_on[code]
            on = value >= CLICK_ON if not on else value > CLICK_OFF
            self.trig_on[code] = on
            self.key(TRIGGER_MAP[code], on, ("abs", code))

    def pwm_tick(self):
        """Drive the PWM buttons; returns the select() timeout until the next tick."""
        args = self.args
        if args.trigger_mode != "pwm":
            return None
        phase = (time.monotonic() * args.pwm_hz) % 1.0
        for code, btn in TRIGGER_MAP.items():
            duty = self.trig[code] / 255
            if duty > 0:
                duty = max(duty, args.pwm_min_pulse * args.pwm_hz)
            self.key(btn, duty >= PWM_FULL or phase < duty, ("abs", code))
        return 0.005 if any(self.trig.values()) else None

    def release_all(self):
        for code in self.trig:
            self.trig[code] = 0
        for code, srcs in self.held.items():
            for src in list(srcs):
                self.key(code, 0, src)


def stick_norm(args, value, info):
    mid = (info.min + info.max) / 2
    half = (info.max - info.min) / 2
    n = (value - mid) / half
    a = abs(n)
    if a < args.deadzone:
        return 0.0
    a = min(1.0, (a - args.deadzone) / (1 - args.deadzone)) ** EXPO
    return a if n > 0 else -a


def run(args, out, mappings):
    main, sibs = find_controller(args.device)
    if main is None:
        return False
    devs = [main] + sibs
    try:
        for d in devs:
            d.grab()
    except OSError as ex:
        log(f"grab failed on {d.path} ({d.name}): {ex} -- is input-remapper still using it?")
        for d in devs:
            try:
                d.ungrab()
            except OSError:
                pass
            d.close()
        return False
    log("grabbed: " + ", ".join(f"{d.path} ({d.name})" for d in devs))

    by_key, by_abs = {}, {}
    for m in mappings:
        (by_key if m.ev_type == e.EV_KEY else by_abs).setdefault(m.code, []).append(m)
    abs_info = {c: main.absinfo(c) for c in by_abs}

    xinfo = main.absinfo(STEER_AXIS)
    out.steer(stick_norm(args, xinfo.value, xinfo))
    for c in TRIGGER_MAP:
        out.trigger(c, main.absinfo(c).value)

    try:
        while True:
            waits = [w for w in (out.pwm_tick(), out.steer_tick()) if w is not None]
            r, _, _ = select.select(devs, [], [], min(waits) if waits else None)
            for d in r:
                for ev in d.read():
                    if d is not main:
                        continue  # touchpad / motion: swallowed
                    if ev.type == e.EV_ABS:
                        if ev.code == STEER_AXIS:
                            out.steer(stick_norm(args, ev.value, xinfo))
                        elif ev.code in TRIGGER_MAP:
                            out.trigger(ev.code, ev.value)
                        for m in by_abs.get(ev.code, ()):
                            out.mapping(m, m.active(ev.value, abs_info[ev.code]))
                    elif ev.type == e.EV_KEY and ev.value in (0, 1):
                        for m in by_key.get(ev.code, ()):
                            out.mapping(m, m.active(ev.value))
    except OSError as ex:
        log(f"device lost: {ex}")
    finally:
        out.release_all()
        out.reset_filter()
        out.move(0)
        for d in devs:
            try:
                d.ungrab()
            except OSError:
                pass
            d.close()
    return True


def main():
    ap = argparse.ArgumentParser(description="Run an input-remapper preset with a DualShock 4 "
                                             "shown to applications as keyboard + mouse.")
    ap.add_argument("preset", nargs="?", help="input-remapper preset JSON (presets/<device>/<name>.json)")
    ap.add_argument("--device", help="controller evdev name (default: the preset's folder name)")
    ap.add_argument("--analyze", metavar="DIR",
                    help="print usable/skipped mapping counts for every preset in DIR as JSON and exit")
    ap.add_argument("--scale", type=float, default=0.9,
                    help="full stick deflection moves the cursor this fraction of center-to-edge")
    ap.add_argument("--deadzone", type=float, default=0.08, help="stick deadzone, fraction of the range")
    ap.add_argument("--cursor-y", type=float, default=0.5,
                    help="fixed vertical cursor position, 0 = top of the screen, 1 = bottom")
    ap.add_argument("--smoothing", action=argparse.BooleanOptionalAction, default=True,
                    help="One Euro filter on the cursor")
    ap.add_argument("--min-cutoff", type=float, default=0.5, help="filter cutoff (Hz) while the stick is still")
    ap.add_argument("--beta", type=float, default=1.0, help="how fast smoothing backs off on quick movements")
    ap.add_argument("--trigger-mode", choices=("pwm", "click"), default="pwm")
    ap.add_argument("--pwm-hz", type=float, default=10.0, help="PWM pulses per second")
    ap.add_argument("--pwm-min-pulse", type=float, default=0.02, help="shortest PWM pulse in seconds")
    args = ap.parse_args()

    if args.analyze:
        print(json.dumps(analyze(args.analyze)))
        return
    if not args.preset:
        ap.error("a preset is required")

    preset = os.path.realpath(args.preset)
    args.device = args.device or os.path.basename(os.path.dirname(preset))
    try:
        mappings, skipped = load_preset(preset)
    except (OSError, ValueError, AttributeError, TypeError) as ex:
        log(f"cannot read preset {preset}: {ex}")
        sys.exit(2)

    lock_fd = single_instance(preset)  # noqa: F841 - must stay open until exit
    log(f"preset: {preset} ({len(mappings)} mappings)")
    for label, reason in skipped:
        log(f"  skipped {label!r}: {reason}")
    if skipped:
        log(f"{len(skipped)} mappings skipped")

    out = Output(args, mappings)

    def bye(*_):
        out.release_all()
        sys.exit(0)

    signal.signal(signal.SIGTERM, bye)
    signal.signal(signal.SIGINT, bye)

    waiting = False
    while True:
        if not run(args, out, mappings):
            if not waiting:
                log(f"waiting for {args.device!r}...")
                waiting = True
            time.sleep(2)
        else:
            waiting = False


if __name__ == "__main__":
    main()
