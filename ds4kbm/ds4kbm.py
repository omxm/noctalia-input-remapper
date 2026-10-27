#!/usr/bin/env python3
"""ds4kbm - use a DualShock 4 as a keyboard + mouse.

The real controller (and its touchpad / motion-sensor nodes) is grabbed
exclusively, so applications only ever see a virtual keyboard and a virtual
absolute pointer - never a gamepad. This keeps games that switch their UI on
"last input device" from flickering between gamepad and mouse modes.

  - left stick X     -> cursor X (absolute), back to center when released
  - R2 / L2          -> mouse buttons, either plain clicks or PWM pulses whose
                        duty cycle follows the trigger depth (analog-ish)
  - face/shoulder... -> keys, as configured

Output events are only written when the output actually changes.

Config lookup order: --config PATH, $DS4KBM_CONFIG,
$XDG_CONFIG_HOME/ds4kbm/config.json, then config.example.json next to this
script.
"""
import argparse
import json
import os
import select
import signal
import sys
import time

import evdev
from evdev import AbsInfo, UInput, ecodes as e

HERE = os.path.dirname(os.path.realpath(__file__))
RANGE = 32767
POINTER_BUTTONS = {e.BTN_LEFT, e.BTN_RIGHT, e.BTN_MIDDLE}

DEFAULTS = {
    "device_name": "Wireless Controller",
    "steer": {"axis": "ABS_X", "scale": 0.9, "deadzone": 0.08, "expo": 1.0},
    "cursor_y": 0.5,
    "triggers": {
        "mode": "pwm",
        "map": {"ABS_RZ": "BTN_LEFT", "ABS_Z": "BTN_RIGHT"},
        "deadzone": 8,
        "click_on": 40,
        "click_off": 20,
        "pwm_hz": 10,
        "pwm_min_pulse": 0.02,
        "pwm_full": 0.95,
    },
    "buttons": {},
}


def log(*a):
    print(*a, file=sys.stderr, flush=True)


def config_path(cli_path):
    if cli_path:
        return cli_path
    if os.environ.get("DS4KBM_CONFIG"):
        return os.environ["DS4KBM_CONFIG"]
    xdg = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    user = os.path.join(xdg, "ds4kbm", "config.json")
    if os.path.exists(user):
        return user
    return os.path.join(HERE, "config.example.json")


def code(name, kind):
    """Resolve an evdev code name such as "KEY_V" or "BTN_SOUTH"."""
    value = e.ecodes.get(name)
    if not isinstance(value, int):
        raise ValueError(f"unknown {kind} code: {name!r}")
    return value


class Config:
    def __init__(self, path):
        with open(path) as f:
            raw = json.load(f)
        steer = {**DEFAULTS["steer"], **raw.get("steer", {})}
        trig = {**DEFAULTS["triggers"], **raw.get("triggers", {})}

        self.path = path
        self.device_name = raw.get("device_name", DEFAULTS["device_name"])
        self.steer_axis = code(steer["axis"], "axis")
        self.scale = float(steer["scale"])
        self.deadzone = float(steer["deadzone"])
        self.expo = float(steer["expo"])
        self.cursor_y = float(raw.get("cursor_y", DEFAULTS["cursor_y"]))

        self.trigger_mode = trig["mode"]
        if self.trigger_mode not in ("pwm", "click"):
            raise ValueError(f"triggers.mode must be 'pwm' or 'click', got {self.trigger_mode!r}")
        self.trigger_map = {code(k, "axis"): code(v, "button") for k, v in trig["map"].items()}
        self.trig_deadzone = int(trig["deadzone"])
        self.click_on = int(trig["click_on"])
        self.click_off = int(trig["click_off"])
        self.pwm_hz = float(trig["pwm_hz"])
        self.pwm_min_pulse = float(trig["pwm_min_pulse"])
        self.pwm_full = float(trig["pwm_full"])

        self.buttons = {code(k, "button"): code(v, "key")
                        for k, v in raw.get("buttons", DEFAULTS["buttons"]).items()
                        if not k.startswith("_")}


def find_controller(cfg):
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
        if not d.name.startswith(cfg.device_name) or d.phys in ("input-remapper", "ds4kbm"):
            d.close()
            continue
        caps = d.capabilities()
        if d.name == cfg.device_name and cfg.steer_axis in [c for c, _ in caps.get(e.EV_ABS, [])]:
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


class Output:
    def __init__(self, cfg):
        self.cfg = cfg
        kbd_keys = sorted({k for k in cfg.buttons.values() if k not in POINTER_BUTTONS}) or [e.KEY_ESC]
        self.kbd = UInput({e.EV_KEY: kbd_keys}, name="ds4kbm keyboard", phys="ds4kbm")
        self.ptr = UInput({
            e.EV_KEY: sorted(POINTER_BUTTONS),
            e.EV_ABS: [
                (e.ABS_X, AbsInfo(0, 0, RANGE, 0, 0, 0)),
                (e.ABS_Y, AbsInfo(0, 0, RANGE, 0, 0, 0)),
            ],
        }, name="ds4kbm pointer", phys="ds4kbm")
        self.down = set()
        self.x = None
        self.trig = {c: 0 for c in cfg.trigger_map}       # current depth 0..255
        self.trig_on = {c: False for c in cfg.trigger_map}

    def key(self, code, val):
        if bool(val) == (code in self.down):
            return
        (self.down.add if val else self.down.discard)(code)
        dev = self.ptr if code in POINTER_BUTTONS else self.kbd
        dev.write(e.EV_KEY, code, 1 if val else 0)
        dev.syn()

    def move(self, n):
        x = round(RANGE / 2 * (1 + n * self.cfg.scale))
        x = max(0, min(RANGE, x))
        if x == self.x:
            return
        first = self.x is None
        self.x = x
        self.ptr.write(e.EV_ABS, e.ABS_X, x)
        if first:
            self.ptr.write(e.EV_ABS, e.ABS_Y, round(self.cfg.cursor_y * RANGE))
        self.ptr.syn()

    def trigger(self, code, value):
        cfg = self.cfg
        if value < cfg.trig_deadzone:
            value = 0
        if cfg.trigger_mode == "pwm":
            self.trig[code] = value
            self.pwm_tick()
        else:
            on = self.trig_on[code]
            on = value >= cfg.click_on if not on else value > cfg.click_off
            self.trig_on[code] = on
            self.key(cfg.trigger_map[code], on)

    def pwm_tick(self):
        """Drive the PWM buttons; returns the select() timeout until the next tick."""
        cfg = self.cfg
        if cfg.trigger_mode != "pwm":
            return None
        phase = (time.monotonic() * cfg.pwm_hz) % 1.0
        for code, btn in cfg.trigger_map.items():
            duty = self.trig[code] / 255
            if duty > 0:
                duty = max(duty, cfg.pwm_min_pulse * cfg.pwm_hz)
            self.key(btn, duty >= cfg.pwm_full or phase < duty)
        return 0.005 if any(self.trig.values()) else None

    def release_all(self):
        for code in self.trig:
            self.trig[code] = 0
        for code in list(self.down):
            self.key(code, 0)


def stick_norm(cfg, value, info):
    mid = (info.min + info.max) / 2
    half = (info.max - info.min) / 2
    n = (value - mid) / half
    a = abs(n)
    if a < cfg.deadzone:
        return 0.0
    a = min(1.0, (a - cfg.deadzone) / (1 - cfg.deadzone)) ** cfg.expo
    return a if n > 0 else -a


def run(cfg, out):
    main, sibs = find_controller(cfg)
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

    xinfo = main.absinfo(cfg.steer_axis)
    out.move(stick_norm(cfg, xinfo.value, xinfo))
    for c in cfg.trigger_map:
        out.trigger(c, main.absinfo(c).value)

    try:
        while True:
            r, _, _ = select.select(devs, [], [], out.pwm_tick())
            for d in r:
                for ev in d.read():
                    if d is not main:
                        continue  # touchpad / motion: swallowed
                    if ev.type == e.EV_ABS:
                        if ev.code == cfg.steer_axis:
                            out.move(stick_norm(cfg, ev.value, xinfo))
                        elif ev.code in cfg.trigger_map:
                            out.trigger(ev.code, ev.value)
                    elif ev.type == e.EV_KEY and ev.code in cfg.buttons:
                        if ev.value in (0, 1):
                            out.key(cfg.buttons[ev.code], ev.value)
    except OSError as ex:
        log(f"device lost: {ex}")
    finally:
        out.release_all()
        out.move(0)
        for d in devs:
            try:
                d.ungrab()
            except OSError:
                pass
            d.close()
    return True


def main():
    ap = argparse.ArgumentParser(description="Use a DualShock 4 as a keyboard + mouse.")
    ap.add_argument("--config", help="path to config JSON")
    ap.add_argument("--check", action="store_true",
                    help="validate the config, print the controller device name and exit")
    args = ap.parse_args()

    path = config_path(args.config)
    try:
        cfg = Config(path)
    except (OSError, ValueError, KeyError, TypeError) as ex:
        log(f"bad config {path}: {ex}")
        sys.exit(2)
    if args.check:
        print(cfg.device_name)
        return
    log(f"config: {path}")

    out = Output(cfg)

    def bye(*_):
        out.release_all()
        sys.exit(0)

    signal.signal(signal.SIGTERM, bye)
    signal.signal(signal.SIGINT, bye)

    waiting = False
    while True:
        if not run(cfg, out):
            if not waiting:
                log(f"waiting for {cfg.device_name!r}...")
                waiting = True
            time.sleep(2)
        else:
            waiting = False


if __name__ == "__main__":
    main()
