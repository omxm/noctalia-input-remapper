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
-- All of it comes from one scan.sh run per refresh (see "refresh" below).
--
-- When a device comes back after a disconnect, the preset in `active` is
-- applied again (input-remapper does not do that by itself). ds4kbm needs no
-- help there: it keeps running and grabs the controller again on its own.

-- ---------------------------------------------------------------------------
-- instrumentation (0.3.1 diagnostic build)
-- ---------------------------------------------------------------------------

local PLUGIN_VERSION = "0.6.1"

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
-- keyboard & mouse mode (ds4kbm)
-- ---------------------------------------------------------------------------

-- Gamepads seen so far, remembered so a disconnected controller still gets
-- its "games see it as" switch in the Saved section.
local knownGamepads = loadJson("gamepads.json")

local analysis = {}

-- How many mappings of each preset ds4kbm can reproduce. Only gamepads can
-- run in keyboard & mouse mode, so only their folders are analyzed. Runs only
-- when the preset tree or the device list changed.
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

-- ---------------------------------------------------------------------------
-- refresh
--
-- Noctalia gives every script callback a small time budget, and a busy system
-- (a game compiling shaders, say) can make even light work blow through it;
-- after a few overruns the plugin gets disabled. So update() does no I/O at
-- all: one scan.sh process gathers everything (input devices, preset folders,
-- daemon and injector state over D-Bus, ds4kbm status) and prints short
-- tab-separated lines, which the callback below only has to split.
-- ---------------------------------------------------------------------------

local cachedTree = {}      -- array of { name, presets }, from the last listing
local treeSig = ""         -- scan.sh fingerprint of that listing
local wasPresent = {}      -- device -> present at the previous refresh
local reapplying = {}      -- device -> true while a re-apply command runs
local lastDevicesJson = nil
local lastDaemonOk = nil

local scanning = false     -- a scan.sh run is in flight
local rescanQueued = false -- another refresh was asked for meanwhile

local function intents()
	local value = noctalia.state.get("active")
	return (type(value) == "table") and value or {}
end

local function split(line)
	local out = {}
	local pos = 1
	while true do
		local tab = string.find(line, "\t", pos, true)
		if tab == nil then
			table.insert(out, string.sub(line, pos))
			return out
		end
		table.insert(out, string.sub(line, pos, tab - 1))
		pos = tab + 1
	end
end

local function scanCmd()
	local dir = noctalia.pluginDir() or "."
	return "DS4KBM_CTL="
		.. shq(dir .. "/ds4kbm/ds4kbm-ctl")
		.. " sh "
		.. shq(dir .. "/scan.sh")
		.. " "
		.. shq(presetsRoot())
		.. " "
		.. shq(treeSig)
end

-- Build the device list from a listing plus the kernel's input devices.
local function buildDevices(tree, inputs)
	local hideEmpty = noctalia.getConfig("hide_empty_devices")
	if hideEmpty == nil then
		hideEmpty = true
	end
	local detect = noctalia.getConfig("detect_connected") ~= false

	-- Copies made by input-remapper / ds4kbm carry the real device's name, so
	-- they are left out: otherwise a controller would look connected for as
	-- long as its copy exists. A `js` handler marks a gamepad, unless the node
	-- is a uinput device. With no input list at all, everything counts as
	-- present rather than hiding devices that are actually plugged in.
	local exact, trimmed = {}, {}
	local learned = false
	for _, rec in ipairs(inputs) do
		local name, phys, uinput, js = rec[2], rec[3], rec[4], rec[5]
		if phys ~= "input-remapper" and phys ~= "ds4kbm" then
			exact[name] = true
			trimmed[trim(name)] = true
			if uinput == "0" and js == "1" and knownGamepads[trim(name)] ~= true then
				knownGamepads[trim(name)] = true
				learned = true
			end
		end
	end
	if learned then
		saveJson("gamepads.json", knownGamepads)
	end

	local devices = {}
	for _, folder in ipairs(tree) do
		local name = folder.name
		-- Exact match first; fall back to a whitespace-insensitive compare so a
		-- folder that lost the device name's padding still matches. `present`
		-- is what the kernel says; `connected` is what the list shows, which
		-- the user can switch off (everything "connected").
		local present = #inputs == 0 or exact[name] == true or trimmed[trim(name)] == true
		if #folder.presets > 0 or not hideEmpty then
			table.insert(devices, {
				name = name,
				display = trim(name),
				presets = folder.presets,
				connected = present or not detect,
				present = present,
				gamepad = knownGamepads[trim(name)] == true,
			})
		end
	end
	table.sort(devices, function(a, b)
		return string.lower(a.display) < string.lower(b.display)
	end)
	return devices
end

-- A device that just came back gets its preset again. The daemon keeps
-- reporting RUNNING for an injector whose device vanished, so the transition
-- in the kernel's device list is what counts, not the daemon state.
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

local requestRefresh -- forward declaration

local function applyScan(stdout)
	local listed = nil -- folder -> presets, when this run listed them
	local order = {}
	local inputs, states = {}, {}
	local sig, daemonOk, kbmPath = nil, false, nil

	for line in string.gmatch(stdout, "[^\n]+") do
		local rec = split(line)
		local kind = rec[1]
		if kind == "input" then
			table.insert(inputs, rec)
		elseif kind == "state" then
			states[rec[2]] = rec[3]
		elseif kind == "dir" then
			table.insert(order, rec[2])
		elseif kind == "preset" and listed ~= nil then
			local list = listed[rec[2]]
			if list == nil then
				list = {}
				listed[rec[2]] = list
			end
			table.insert(list, rec[3])
		elseif kind == "sig" then
			sig = rec[2]
			if rec[3] == "new" then
				listed = {}
			end
		elseif kind == "daemon" then
			daemonOk = rec[2] == "ok"
		elseif kind == "ds4kbm" and rec[2] == "on" then
			kbmPath = rec[3]
		end
	end

	-- Preset tree: rebuilt only when scan.sh saw the fingerprint change.
	if listed ~= nil then
		local tree = {}
		for _, name in ipairs(order) do
			local presets = listed[name] or {}
			table.sort(presets, function(a, b)
				return string.lower(a) < string.lower(b)
			end)
			table.insert(tree, { name = name, presets = presets })
		end
		cachedTree = tree
		treeSig = sig or ""
	end

	local devices = buildDevices(cachedTree, inputs)
	local before = wasPresent
	wasPresent = {}
	for _, entry in ipairs(devices) do
		wasPresent[entry.name] = entry.present
	end

	-- Daemon. No daemon means nothing can possibly be injecting, so drop any
	-- remembered state instead of showing a stale "running" badge.
	if daemonOk ~= lastDaemonOk then
		lastDaemonOk = daemonOk
		dbg("daemon -> " .. (daemonOk and "ok" or "down"))
		noctalia.state.set("daemon", daemonOk and "ok" or "down")
	end
	local wanted = intents()
	local changed = false
	if not daemonOk and next(wanted) ~= nil then
		wanted = {}
		changed = true
	end

	-- ds4kbm. It releases the controller from input-remapper when it starts,
	-- so a remembered preset for that device is no longer injecting.
	if kbmPath == nil or kbmPath == "" then
		ds4kbm = { state = "off" }
	else
		local device, preset = string.match(kbmPath, "([^/]+)/([^/]+)%.json%s*$")
		ds4kbm = { state = "on", device = device, preset = preset, path = kbmPath }
		if device ~= nil and wanted[device] ~= nil then
			wanted[device] = nil
			changed = true
		end
	end
	publishDs4kbm()

	-- Injection state from the daemon. It keeps saying RUNNING after a device
	-- is unplugged; only a present device really injects. Its preset stays in
	-- `active` so it is re-applied when the device comes back.
	local running = {}
	for _, entry in ipairs(devices) do
		local device = entry.name
		local state = states[device] or "ERR"
		if (state == "RUNNING" or state == "STARTING") and entry.present then
			running[device] = wanted[device] or ""
		elseif daemonOk and wanted[device] ~= nil and entry.present and before[device] == true and not reapplying[device] then
			-- Plugged in for two refreshes in a row and still not injecting:
			-- stopped elsewhere (GUI) or failed, so stop claiming it.
			dbg("intent dropped for " .. device .. " (daemon says " .. state .. ")")
			wanted[device] = nil
			changed = true
		end
	end
	if changed then
		noctalia.state.set("active", wanted)
	end
	if noctalia.json.encode(running) ~= noctalia.json.encode(noctalia.state.get("running")) then
		noctalia.state.set("running", running)
	end

	reapplyReconnected(devices, before)

	local encoded = noctalia.json.encode(devices)
	if encoded ~= lastDevicesJson then
		lastDevicesJson = encoded
		dbg("publish devices=" .. tostring(#devices))
		noctalia.state.set("devices", devices)
		analyzePresets(devices)
	end
end

-- Start a refresh unless one is already running; a request that arrives
-- meanwhile is remembered and runs right after, so refreshes never pile up.
requestRefresh = function()
	if scanning then
		rescanQueued = true
		return
	end
	scanning = true
	noctalia.runAsync(scanCmd(), function(result)
		scanning = false
		if result ~= nil and result.exitCode == 0 then
			applyScan(result.stdout or "")
		else
			dbg("scan.sh failed exit=" .. tostring(result and result.exitCode))
		end
		if rescanQueued then
			rescanQueued = false
			requestRefresh()
		end
	end)
end

-- Forget the preset listing so the next refresh rebuilds it (Reload, open,
-- settings change).
local function refreshAll()
	treeSig = ""
	lastDevicesJson = nil
	requestRefresh()
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
	noctalia.runAsync(ds4kbmCmd("stop"), function(_result)
		requestRefresh()
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
requestRefresh()

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

	-- Everything happens in scan.sh and its callback; see "refresh" above.
	requestRefresh()
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
				requestRefresh()
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
