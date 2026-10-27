-- haru/input-remapper : service.luau
--
-- Owns the truth for the whole plugin and publishes it on noctalia.state:
--
--   devices      : array of { name, display, presets, connected, present, gamepad }
--   active       : map device name -> preset meant to be injected by
--                  input-remapper (what we asked for, persisted)
--   running      : map device name -> preset input-remapper is injecting
--                  right now, per the daemon over D-Bus ("" when it runs a
--                  preset this plugin did not start)
--   daemon       : "ok" | "down"
--   modes        : map device name -> "kbm" for gamepads shown to games as
--                  keyboard & mouse (absent = "controller")
--   ds4kbm       : { state = "on" | "off", device, preset, path }
--   kbm_analysis : map device name -> preset name -> { usable, skipped }
--
-- The panel writes back to `active` and `modes`; this service persists both
-- so they survive a Noctalia restart. `running` and `ds4kbm` are only ever
-- written here; the panel bumps `scan_request` after every start or stop.
--
-- When a device comes back after a disconnect, the preset in `active` is
-- applied again (input-remapper does not do that by itself). ds4kbm needs no
-- help there: it keeps running and grabs the controller again on its own.

-- ---------------------------------------------------------------------------
-- instrumentation (0.3.1 diagnostic build)
-- ---------------------------------------------------------------------------

local PLUGIN_VERSION = "0.6.0"

local VM_ID = string.format("%04x", (noctalia.nowMs() % 65536))
	.. string.format("%02x", math.random(0, 255))

local LOG_PATH = nil
local logResolved = false

local function logPath()
	if logResolved then
		return LOG_PATH
	end
	logResolved = true
	local dir = noctalia.pluginDataDir()
	if dir ~= nil then
		LOG_PATH = dir .. "/debug.log"
	end
	return LOG_PATH
end

local function dbg(message)
	if noctalia.getConfig("debug_log") == false then
		return
	end
	local path = logPath()
	if path == nil then
		return
	end

	local ms = noctalia.nowMs()
	local stamp = noctalia.formatTime("{:%H:%M:%S}") .. "." .. string.format("%03d", ms % 1000)
	local line = stamp .. "  svc/" .. VM_ID .. "    " .. message .. "\n"

	local existing = ""
	if noctalia.fileExists(path) then
		existing = noctalia.readFile(path) or ""
	end
	if #existing > 60000 then
		existing = string.sub(existing, -30000)
	end
	noctalia.writeFile(path, existing .. line)
end

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------

-- POSIX single-quote escaping. Device names here contain spaces, commas, and
-- (for the AJAZZ) seven leading spaces, so every interpolated value must go
-- through this before it touches /bin/sh.
local function shq(value)
	local escaped = string.gsub(tostring(value), "'", "'\\''")
	return "'" .. escaped .. "'"
end

local function trim(value)
	local result = string.gsub(tostring(value), "^%s*(.-)%s*$", "%1")
	return result
end

local function controlCmd()
	local cmd = noctalia.getConfig("control_cmd")
	if cmd == nil or cmd == "" then
		return "input-remapper-control"
	end
	return cmd
end

local function stopCmd(device)
	return controlCmd() .. " --command stop --device " .. shq(device)
end

local function startCmd(device, preset)
	return controlCmd() .. " --command start --device " .. shq(device) .. " --preset " .. shq(preset)
end

local function presetsRoot()
	local dir = noctalia.getConfig("config_dir")
	if dir == nil or dir == "" then
		dir = "~/.config/input-remapper-2"
	end
	return noctalia.expandPath(dir) .. "/presets"
end

-- ds4kbm/ds4kbm-ctl, with input-remapper's control command handed down so a
-- wrapper configured in the plugin settings is honored there too.
local function ds4kbmCmd(sub)
	local dir = noctalia.pluginDir() or "."
	return "DS4KBM_REMAPPER_CMD="
		.. shq(controlCmd())
		.. " "
		.. shq(dir .. "/ds4kbm/ds4kbm-ctl")
		.. " "
		.. sub
end

-- Tuning from the plugin settings, as ds4kbm.py options. Kept identical to
-- the copy in panel.luau.
local function ds4kbmArgs()
	local function num(key, fallback)
		local value = noctalia.getConfig(key)
		if type(value) ~= "number" then
			value = fallback
		end
		return string.format("%g", value)
	end
	local mode = noctalia.getConfig("kbm_trigger_mode")
	if mode ~= "click" then
		mode = "pwm"
	end
	return " --scale " .. num("kbm_scale", 0.9)
		.. " --deadzone " .. num("kbm_deadzone", 0.08)
		.. " --cursor-y " .. num("kbm_cursor_y", 0.5)
		.. (noctalia.getConfig("kbm_smoothing") == false and " --no-smoothing" or " --smoothing")
		.. " --min-cutoff " .. num("kbm_min_cutoff", 0.5)
		.. " --beta " .. num("kbm_beta", 1.0)
		.. " --trigger-mode " .. mode
		.. " --pwm-hz " .. num("kbm_pwm_hz", 10)
		.. " --pwm-min-pulse " .. num("kbm_pwm_min_pulse", 0.02)
end

-- ---------------------------------------------------------------------------
-- persistence
-- ---------------------------------------------------------------------------

local function dataPath(file)
	local dir = noctalia.pluginDataDir()
	if dir == nil then
		return nil
	end
	return dir .. "/" .. file
end

local function saveJson(file, value)
	local path = dataPath(file)
	if path == nil then
		return
	end
	local encoded = noctalia.json.encode(value)
	if encoded ~= nil then
		noctalia.writeFile(path, encoded)
	end
end

local function loadJson(file)
	local path = dataPath(file)
	if path == nil or not noctalia.fileExists(path) then
		return {}
	end
	local raw = noctalia.readFile(path)
	if raw == nil then
		return {}
	end
	local decoded = noctalia.json.decode(raw)
	if type(decoded) ~= "table" then
		return {}
	end
	return decoded
end

-- ---------------------------------------------------------------------------
-- connected devices
-- ---------------------------------------------------------------------------

-- Gamepads seen so far, remembered so a disconnected controller still gets
-- its "games see it as" switch in the Saved section.
local knownGamepads = loadJson("gamepads.json")

-- /proc/bus/input/devices lists every evdev device the kernel currently knows
-- about, one block per device, with lines like:
--     N: Name="       AJAZZ 2.4G 8K"
--     P: Phys=usb-0000:0a:00.3-2.4/input0
--     S: Sysfs=/devices/virtual/misc/uhid/0005:054C:09CC.0008/input/input25
--     H: Handlers=event25 js0
-- It is world-readable and generated in-kernel, so this needs no root, no
-- D-Bus, and no call into input-remapper.
--
-- Copies made by input-remapper / ds4kbm (Phys "input-remapper" / "ds4kbm")
-- carry the real device's name, so they are left out: otherwise a controller
-- would look connected for as long as its copy exists. A `js` handler marks a
-- gamepad, unless the node is a uinput device (/devices/virtual/input/...).
--
-- Returns two sets (exact names, trimmed names), or nil when the file cannot
-- be read - in which case callers should treat every device as connected
-- rather than hiding things that are actually plugged in.
local function connectedNames()
	local raw = noctalia.readFile("/proc/bus/input/devices")
	if raw == nil then
		noctalia.log("input-remapper: cannot read /proc/bus/input/devices, showing every device")
		return nil
	end

	local exact, trimmed = {}, {}
	local found = false
	local learned = false
	for block in string.gmatch(raw .. "\n\n", "(.-)\n%s*\n") do
		local name = string.match(block, 'N: Name="(.-)"%s*\n') or string.match(block, 'N: Name="(.-)"%s*$')
		local phys = string.match(block, "P: Phys=([^\n]*)") or ""
		local uinput = string.find(block, "S: Sysfs=/devices/virtual/input/", 1, true) ~= nil
		local handlers = string.match(block, "H: Handlers=([^\n]*)") or ""
		if name ~= nil and phys ~= "input-remapper" and phys ~= "ds4kbm" then
			found = true
			exact[name] = true
			trimmed[trim(name)] = true
			if not uinput and string.find(" " .. handlers, " js%d") and knownGamepads[trim(name)] ~= true then
				knownGamepads[trim(name)] = true
				learned = true
			end
		end
	end
	if learned then
		saveJson("gamepads.json", knownGamepads)
	end

	if not found then
		return nil
	end
	return exact, trimmed
end

-- ---------------------------------------------------------------------------
-- scanning
-- ---------------------------------------------------------------------------

-- Device names and preset names come straight from the directory tree, so no
-- root privileges and no D-Bus round trip are needed to build the list.
local function scanDevices()
	local root = presetsRoot()
	local entries = noctalia.listDir(root)
	if entries == nil then
		noctalia.log("input-remapper: cannot read " .. root)
		return {}
	end

	local hideEmpty = noctalia.getConfig("hide_empty_devices")
	if hideEmpty == nil then
		hideEmpty = true
	end

	local exactSet, trimmedSet = connectedNames()
	local detect = noctalia.getConfig("detect_connected") ~= false

	local devices = {}
	for _, name in ipairs(entries) do
		local full = root .. "/" .. name
		local info = noctalia.fileInfo(full)
		if info ~= nil and info.isDir then
			local files = noctalia.listDir(full)
			local presets = {}
			if files ~= nil then
				for _, file in ipairs(files) do
					if #file > 5 and string.sub(file, -5) == ".json" then
						table.insert(presets, string.sub(file, 1, #file - 5))
					end
				end
			end
			table.sort(presets, function(a, b)
				return string.lower(a) < string.lower(b)
			end)

			-- Exact match first; fall back to a whitespace-insensitive compare
			-- so a folder that lost the device name's padding still matches.
			-- `present` is what the kernel says; `connected` is what the list
			-- shows, which the user can switch off (everything "connected").
			local present = true
			if exactSet ~= nil then
				present = (exactSet[name] == true) or (trimmedSet[trim(name)] == true)
			end
			local connected = present or not detect

			if #presets > 0 or not hideEmpty then
				table.insert(devices, {
					name = name,
					display = trim(name),
					presets = presets,
					connected = connected,
					present = present,
					gamepad = knownGamepads[trim(name)] == true,
				})
			end
		end
	end

	table.sort(devices, function(a, b)
		return string.lower(a.display) < string.lower(b.display)
	end)
	return devices
end

-- ---------------------------------------------------------------------------
-- keyboard & mouse mode (ds4kbm)
-- ---------------------------------------------------------------------------

local analysis = {}

-- How many mappings of each preset ds4kbm can reproduce. Only gamepads can
-- run in keyboard & mouse mode, so only their folders are analyzed.
local function analyzePresets(devices)
	for _, entry in ipairs(devices) do
		if entry.gamepad then
			local device = entry.name
			noctalia.runAsync(ds4kbmCmd("analyze " .. shq(presetsRoot() .. "/" .. device)), function(result)
				if result == nil or result.exitCode ~= 0 then
					dbg("analyze failed for " .. device)
					return
				end
				local decoded = noctalia.json.decode(result.stdout or "")
				if type(decoded) ~= "table" then
					return
				end
				if noctalia.json.encode(decoded) ~= noctalia.json.encode(analysis[device]) then
					analysis[device] = decoded
					noctalia.state.set("kbm_analysis", analysis)
				end
			end)
		end
	end
end

local ds4kbm = { state = "off" }
local kbmArgs = ds4kbmArgs()

local function publishDs4kbm()
	-- Compare against what is actually in state rather than a private cache,
	-- so the published value can never get stuck behind a stale copy.
	if noctalia.json.encode(ds4kbm) ~= noctalia.json.encode(noctalia.state.get("ds4kbm")) then
		dbg("ds4kbm -> " .. ds4kbm.state .. " " .. tostring(ds4kbm.device) .. " / " .. tostring(ds4kbm.preset))
		noctalia.state.set("ds4kbm", ds4kbm)
	end
end

local function checkDs4kbm()
	noctalia.runAsync(ds4kbmCmd("status"), function(result)
		local path = nil
		if result ~= nil and result.exitCode == 0 then
			path = string.match(result.stdout or "", "\n([^\n]+)")
		end

		if path == nil then
			ds4kbm = { state = "off" }
		else
			local device, preset = string.match(path, "([^/]+)/([^/]+)%.json%s*$")
			ds4kbm = { state = "on", device = device, preset = preset, path = path }
		end

		-- ds4kbm releases the controller from input-remapper when it starts,
		-- so a remembered preset for that device is no longer injecting.
		if ds4kbm.device ~= nil then
			local current = noctalia.state.get("active")
			if type(current) == "table" and current[ds4kbm.device] ~= nil then
				local copy = {}
				for k, v in pairs(current) do
					copy[k] = v
				end
				copy[ds4kbm.device] = nil
				noctalia.state.set("active", copy)
			end
		end

		publishDs4kbm()
	end)
end

-- ---------------------------------------------------------------------------
-- publishing
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- input-remapper injection state (D-Bus) and re-applying after reconnects
-- ---------------------------------------------------------------------------

local wasPresent = {}   -- device -> present at the previous scan
local reapplying = {}   -- device -> true while a re-apply command runs

local function intents()
	local value = noctalia.state.get("active")
	return (type(value) == "table") and value or {}
end

-- One shell call asks the daemon for every device's injector state, one line
-- per device. dbus-send ships with dbus itself, so nothing new is needed.
local function statesCmd(devices)
	local names = {}
	for _, entry in ipairs(devices) do
		table.insert(names, shq("string:" .. entry.name))
	end
	return "for arg in "
		.. table.concat(names, " ")
		.. "; do dbus-send --system --print-reply=literal --dest=inputremapper.Control"
		.. " /inputremapper/Control inputremapper.Control.get_state \"$arg\" 2>/dev/null || printf ERR; echo; done"
end

-- `before` maps device -> present at the scan before this one.
local function checkStates(devices, before)
	if #devices == 0 then
		return
	end
	noctalia.runAsync(statesCmd(devices), function(result)
		if result == nil or result.exitCode ~= 0 then
			return
		end
		local states = {}
		for line in string.gmatch((result.stdout or "") .. "\n", "([^\n]*)\n") do
			table.insert(states, trim(line))
		end

		local wanted = intents()
		local running = {}
		local dropped = false
		for i, entry in ipairs(devices) do
			local device = entry.name
			local state = states[i] or "ERR"
			-- The daemon keeps saying RUNNING after the device is unplugged;
			-- only a present device really injects. Its preset stays in
			-- `active` so it is re-applied when the device comes back.
			if (state == "RUNNING" or state == "STARTING") and entry.present then
				running[device] = wanted[device] or ""
			elseif wanted[device] ~= nil and entry.present and before[device] == true and not reapplying[device] then
				-- Plugged in for two scans in a row and still not injecting:
				-- stopped elsewhere (GUI) or failed, so stop claiming it.
				dbg("intent dropped for " .. device .. " (daemon says " .. state .. ")")
				wanted[device] = nil
				dropped = true
			end
		end

		if dropped then
			noctalia.state.set("active", wanted)
		end
		if noctalia.json.encode(running) ~= noctalia.json.encode(noctalia.state.get("running")) then
			noctalia.state.set("running", running)
		end
	end)
end

-- A device that just came back gets its preset again. The daemon keeps
-- reporting RUNNING for an injector whose device vanished, so the transition
-- in /proc is what counts, not the daemon state.
local function reapplyReconnected(devices, before)
	local wanted = intents()
	for _, entry in ipairs(devices) do
		local device = entry.name
		local preset = wanted[device]
		if preset ~= nil and entry.present and before[device] == false and not reapplying[device] then
			reapplying[device] = true
			dbg("reconnected " .. device .. ", re-applying " .. preset)
			noctalia.runAsync(startCmd(device, preset), function(result)
				reapplying[device] = nil
				if result == nil or result.exitCode ~= 0 then
					dbg("RE-APPLY FAILED " .. device .. " -> " .. preset)
				end
				noctalia.state.set("scan_request", noctalia.nowMs())
			end)
		end
	end
end

local lastDevicesJson = nil
local lastDaemonOk = nil

local function publishDevices()
	local devices = scanDevices()

	local before = wasPresent
	wasPresent = {}
	for _, entry in ipairs(devices) do
		wasPresent[entry.name] = entry.present
	end
	reapplyReconnected(devices, before)
	checkStates(devices, before)

	local encoded = noctalia.json.encode(devices)
	if encoded ~= lastDevicesJson then
		lastDevicesJson = encoded
		local connectedCount = 0
		for _, d in ipairs(devices) do
			if d.connected then
				connectedCount = connectedCount + 1
			end
		end
		dbg("publish devices=" .. tostring(#devices) .. " connected=" .. tostring(connectedCount))
		noctalia.state.set("devices", devices)
		analyzePresets(devices)
	end
end

local function checkDaemon()
	noctalia.runAsync(controlCmd() .. " --command hello", function(result)
		local ok = (result ~= nil and result.exitCode == 0)

		if ok ~= lastDaemonOk then
			lastDaemonOk = ok
			dbg("daemon -> " .. (ok and "ok" or "down"))
			noctalia.state.set("daemon", ok and "ok" or "down")
		end

		-- No daemon means nothing can possibly be injecting, so drop any
		-- remembered state instead of showing a stale "running" badge.
		if not ok then
			local current = noctalia.state.get("active")
			if type(current) == "table" and next(current) ~= nil then
				noctalia.state.set("active", {})
			end
		end
	end)
end

local function refreshAll()
	lastDevicesJson = nil
	publishDevices()
	checkDaemon()
	checkDs4kbm()
end

local function stopAll()
	-- Everything we asked for plus everything the daemon says runs (it may
	-- have been started from the GUI).
	local targets = {}
	for _, key in ipairs({ "active", "running" }) do
		local map = noctalia.state.get(key)
		if type(map) == "table" then
			for device, _ in pairs(map) do
				targets[device] = true
			end
		end
	end
	for device, _ in pairs(targets) do
		noctalia.runAsync(stopCmd(device))
	end
	noctalia.state.set("active", {})
	noctalia.state.set("scan_request", noctalia.nowMs())
	noctalia.runAsync(ds4kbmCmd("stop"), function(_result)
		checkDs4kbm()
	end)
end

-- ---------------------------------------------------------------------------
-- startup
-- ---------------------------------------------------------------------------

local startupActive = loadJson("active.json")
local startupMode = noctalia.getConfig("on_startup")
if startupMode == nil or startupMode == "" then
	startupMode = "restore"
end

if startupMode == "clear" then
	startupActive = {}
	saveJson("active.json", startupActive)
elseif startupMode == "stop_all" then
	for device, _ in pairs(startupActive) do
		noctalia.runAsync(stopCmd(device))
	end
	noctalia.runAsync(ds4kbmCmd("stop"))
	startupActive = {}
	saveJson("active.json", startupActive)
end

dbg("=== service VM loaded (v" .. PLUGIN_VERSION .. ") mode=" .. tostring(startupMode) .. " ===")
dbg("presets root: " .. presetsRoot())
dbg("plugin dir:   " .. tostring(noctalia.pluginDir()))
dbg("data dir:     " .. tostring(noctalia.pluginDataDir()))

noctalia.state.set("active", startupActive)
noctalia.state.set("running", {})
noctalia.state.set("modes", loadJson("modes.json"))
noctalia.state.set("kbm_analysis", analysis)
publishDevices()
checkDaemon()
checkDs4kbm()

-- ---------------------------------------------------------------------------
-- watches
-- ---------------------------------------------------------------------------

noctalia.state.watch("active", function(value)
	if type(value) == "table" then
		saveJson("active.json", value)
	end
end)

noctalia.state.watch("modes", function(value)
	if type(value) == "table" then
		saveJson("modes.json", value)
	end
end)

-- The panel bumps this to ask for an immediate rescan (Reload button / open,
-- and after starting or stopping ds4kbm).
noctalia.state.watch("scan_request", function(_value)
	refreshAll()
end)

noctalia.state.watch("stop_all_request", function(_value)
	stopAll()
end)

-- ---------------------------------------------------------------------------
-- lifecycle
-- ---------------------------------------------------------------------------

function update()
	local seconds = noctalia.getConfig("poll_seconds")
	if type(seconds) ~= "number" or seconds < 2 then
		seconds = 5
	end
	noctalia.setUpdateInterval(seconds * 1000)

	publishDevices()
	checkDaemon()
	checkDs4kbm()
end

function onConfigChanged()
	lastDaemonOk = nil
	refreshAll()

	-- New tuning takes effect right away: restart a running ds4kbm with the
	-- same preset and the new options.
	local args = ds4kbmArgs()
	if args ~= kbmArgs then
		kbmArgs = args
		if ds4kbm.state == "on" and ds4kbm.path ~= nil then
			dbg("ds4kbm tuning changed, restarting")
			noctalia.runAsync(ds4kbmCmd("start " .. shq(ds4kbm.path) .. args), function(_result)
				checkDs4kbm()
			end)
		end
	end
end

-- noctalia msg plugin haru/input-remapper:service all reload
-- noctalia msg plugin haru/input-remapper:service all stop-all
function onIpc(event, _payload)
	if event == "reload" then
		refreshAll()
	elseif event == "stop-all" then
		stopAll()
	end
end

function onExit(signal, reason)
	dbg("onExit signal=" .. tostring(signal) .. " reason=" .. tostring(reason))
end
