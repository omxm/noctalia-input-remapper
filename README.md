# Input Remapper for Noctalia v5

A plugin that lets you switch [input-remapper](https://github.com/sezanzeb/input-remapper)
presets directly from the bar. No password prompts, no window juggling, one
right-click to stop everything.

Target: Noctalia v5.0.0+ (`plugin_api = 18`) / input-remapper 2.x

This is my very first project, so please go easy on me!
---
## Example
<img width="619" height="602" alt="screenshot_20260820_094651-region" src="https://github.com/user-attachments/assets/0c2f72d3-5180-4158-82e3-99e8561b5859" />

## Installation is two steps

**Install the runit service first.** Skipping this means you'll still get a
password prompt every time, even with the plugin installed.

### 1. Keep the daemon resident as root (Artix / runit)

The password prompt exists because `input-remapper-service` isn't resident -
the GUI re-launches it as root via `pkexec` every single time. Running it as
a runit system service from boot removes that path entirely.

```sh
# Confirm the binary's location first (on Arch/Artix, /usr/sbin is a symlink to /usr/bin)
command -v input-remapper-service

sudo mkdir -p /etc/runit/sv/input-remapper/log
sudo cp runit/input-remapper/run     /etc/runit/sv/input-remapper/run
sudo cp runit/input-remapper/log/run /etc/runit/sv/input-remapper/log/run
sudo chmod +x /etc/runit/sv/input-remapper/run /etc/runit/sv/input-remapper/log/run
sudo mkdir -p /var/log/input-remapper

# enable
sudo ln -s /etc/runit/sv/input-remapper /run/runit/service/

# verify
sudo sv status input-remapper
input-remapper-control --command hello     # -> Daemon answered with "hello"
```

`run` waits on `sv check dbus` before exec'ing. input-remapper publishes
`inputremapper.Control` on the system bus, so starting before dbus is up
would fail.

If something's off, check `sudo tail -f /var/log/input-remapper/current`.

> **About the GUI**: recording a *new* mapping still needs root, because
> `input-remapper-reader-service` requests it separately. You'll still see a
> prompt there. Applying or stopping presets - what this plugin does - never
> triggers one.

### 2. Drop in the plugin

```sh
mkdir -p ~/.local/share/noctalia/plugins
rm -rf ~/.local/share/noctalia/plugins/input-remapper
cp -r input-remapper ~/.local/share/noctalia/plugins/
```

The `rm -rf` first matters: if a same-named directory already exists,
`cp -r` nests the copy inside it instead of overwriting.

Enable **Input Remapper** under Noctalia's Settings → Plugins, then add the
`haru/input-remapper:indicator` widget to your bar wherever you like.

`.luau` files hot-reload automatically, but `plugin.toml` only takes effect on
the next config reload. **Fully restart Noctalia whenever you swap in a new
version** - a hot reload alone can leave the script and the manifest on
different generations at the same time.

---

## Usage

| Action | Effect |
|---|---|
| Left-click the widget | Toggle the panel |
| Right-click the widget | Stop every running injection |
| Middle-click the widget | Widget settings (standard Noctalia behavior) |
| Click a preset row | Switch to it. Click again while active to stop it |
| Start / Stop on a device row | Start with the last-picked (or first) preset / stop |
| Reload | Rescan presets and re-check the daemon |
| Stop all | Stop every running injection |

The `setted` badge means that preset is **currently injecting**.

Also reachable over IPC:

```sh
noctalia msg panel-toggle haru/input-remapper:panel
noctalia msg plugin haru/input-remapper:service all reload
noctalia msg plugin haru/input-remapper:service all stop-all
```

---

## Settings

Settings → Plugins → the gear icon on this plugin's row.

| Key | Default | Description |
|---|---|---|
| `config_dir` | `~/.config/input-remapper-2` | Where `presets/` and `config.json` live |
| `control_cmd` | `input-remapper-control` | The executable used to talk to the daemon. Inserted unquoted, so it can carry a wrapper |
| `poll_seconds` | `5` | How often to rescan presets and ping the daemon |
| `hide_empty_devices` | `true` | Hide folders with no `.json` presets |
| `detect_connected` | `true` | Split devices into Connected / Saved based on whether they're plugged in |
| `scroll_height` | `0` | List height. `0` = automatic; set a number only if the footer gets pushed off |
| `debug_log` | `false` | Write diagnostics to `<pluginDataDir>/debug.log`. Only needed while troubleshooting |
| `on_startup` | `restore` | What to do with the remembered injection state when Noctalia starts |

Widget settings (bar widget config):

| Key | Default | Description |
|---|---|---|
| `show_label` | `true` | Show the preset name in the bar when exactly one injection is running |
| `max_label_chars` | `18` | Truncate names longer than this |

---

## Design notes

**Getting devices and presets**
Rather than `--list-devices` (which needs root), the plugin reads the
`presets/` directory tree directly. Folder names match what `--device`
expects, so no root and no D-Bus round trip are needed - and it's fast.

**Connection detection**
Reads `N: Name="..."` lines from `/proc/bus/input/devices` and matches them
against folder names. World-readable and kernel-generated, so again no root
or D-Bus. Falls back to a whitespace-insensitive comparison if an exact match
fails (this covers cases like the seven leading spaces on some AJAZZ
receivers). If the file can't be read, or no names come back at all, every
device is treated as Connected - a failed detection never makes a device
disappear. A device that's currently injecting is always shown as Connected
regardless of what detection concluded.

**Panel layout**
`flexGrow` only distributes *leftover* space. Earlier builds gave the root
column no height of its own, so it shrank to fit its children, leftover was
always zero, and the scroll area silently fell back to taking its content
height instead: tall content pushed the footer off the panel, and a stale
small measurement squashed the list to a sliver. Toggling a section changed
the content height, which made the layout appear to change at random.

The fix is to give the root column an explicit height so real leftover space
exists for `flexGrow` to distribute. That height is read from `plugin.toml`
at runtime instead of being hardcoded, so the script and the manifest can
never drift out of sync the way they briefly did in earlier iterations (`.luau`
hot-reloads immediately; `plugin.toml` doesn't, so a hardcoded copy could go
stale between the two). If the manifest can't be read, it falls back to `540`.

A `scroll_height` setting (`0` = automatic) remains as a manual override in
case `flexGrow` ever fails to constrain on some compositor.

**Shell quoting**
At `plugin_api = 18`, `runAsync`'s array-argument form isn't guaranteed
available on older hosts, so this plugin builds commands as shell strings for
safety. Device names can contain spaces, commas, and leading whitespace (some
AJAZZ receivers report seven leading spaces), so every interpolated value goes
through POSIX single-quote escaping (`'` -> `'\''`).

**State tracking**
input-remapper has no CLI to report which preset is currently injecting, so
the plugin remembers the start/stop commands it issued and persists that to
`pluginDataDir()`. If the daemon becomes unreachable, injection is impossible
by definition, so the remembered state is dropped. If the GUI is used
alongside the plugin and the two fall out of sync, Reload fixes it.

**Communication between entries**
`service` is the single source of truth: it publishes `devices` / `active` /
`daemon` to `noctalia.state`, and `panel` / `widget` watch them. `panel`
writes back to `active` after a command succeeds.

---

## Known limitations

- **Stray preset files show up as-is**: e.g. a leftover
  `Akko Keyboard/Roblox_Evade_macro copy.json` will appear in the list.
  Easiest fix is just deleting it.
- **Folder name vs. evdev device name mismatch**: usually they match, but if
  they don't, `start` fails with "device unknown". A notification appears
  when this happens - cross-check with
  `sudo input-remapper-control --list-devices`.
- **Connection detection is name-based**: a mismatched folder/evdev name
  falls into Saved. Saved cards aren't disabled, so you can still try
  starting one - a misdetection never locks you out. Turn off
  `detect_connected` if this bothers you.
- **No autoload support**: `config.json`'s `autoload` is empty by default, so
  there's no UI for it yet. Could be added later as an "applies on startup"
  badge.
- **Injection state is self-reported, not measured**: the daemon's D-Bus
  interface exposes `get_state`, which could replace the current
  self-tracking approach and eliminate drift when the GUI is used at the same
  time.

## License

MIT
