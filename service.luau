-- haru/input-remapper : service.luau
--
-- Owns the truth for the whole plugin and publishes it on noctalia.state:
--
--   devices : array of { name, display, presets = { "a", "b", ... } }
--   active  : map  device name -> preset name currently injecting
--   daemon  : "ok" | "down"
--
-- The panel writes back to `active` after it runs a start/stop command; this
-- service persists that map so it survives a Noctalia restart.

-- ---------------------------------------------------------------------------
-- instrumentation (0.3.1 diagnostic build)
-- ---------------------------------------------------------------------------

local PLUGIN_VERSION = "0.4.0"

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

local function presetsRoot()
	local dir = noctalia.getConfig("config_dir")
	if dir == nil or dir == "" then
		dir = "~/.config/input-remapper-2"
	end
	return noctalia.expandPath(dir) .. "/presets"
end

-- ---------------------------------------------------------------------------
-- persistence
-- ---------------------------------------------------------------------------

local function statePath()
	local dir = noctalia.pluginDataDir()
	if dir == nil then
		return nil
	end
	return dir .. "/active.json"
end

local function saveActive(map)
	local path = statePath()
	if path == nil then
		return
	end
	local encoded = noctalia.json.encode(map)
	if encoded ~= nil then
		noctalia.writeFile(path, encoded)
	end
end

local function loadActive()
	local path = statePath()
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

-- /proc/bus/input/devices lists every evdev device the kernel currently knows
-- about, one block per device, with a line like:
--     N: Name="       AJAZZ 2.4G 8K"
-- It is world-readable and generated in-kernel, so this needs no root, no
-- D-Bus, and no call into input-remapper.
--
-- Returns two sets (exact names, trimmed names), or nil when the file cannot
-- be read - in which case callers should treat every device as connected
-- rather than hiding things that are actually plugged in.
local function connectedNames()
	local detect = noctalia.getConfig("detect_connected")
	if detect == false then
		return nil
	end

	local raw = noctalia.readFile("/proc/bus/input/devices")
	if raw == nil then
		noctalia.log("input-remapper: cannot read /proc/bus/input/devices, showing every device")
		return nil
	end

	local exact, trimmed = {}, {}
	local found = false
	for line in string.gmatch(raw, "[^\r\n]+") do
		local name = string.match(line, '^N: Name="(.*)"%s*$')
		if name ~= nil then
			found = true
			exact[name] = true
			trimmed[trim(name)] = true
		end
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
			local connected = true
			if exactSet ~= nil then
				connected = (exactSet[name] == true) or (trimmedSet[trim(name)] == true)
			end

			if #presets > 0 or not hideEmpty then
				table.insert(devices, {
					name = name,
					display = trim(name),
					presets = presets,
					connected = connected,
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
-- publishing
-- ---------------------------------------------------------------------------

local lastDevicesJson = nil
local lastDaemonOk = nil

local function publishDevices()
	local devices = scanDevices()
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

local function stopAll()
	local current = noctalia.state.get("active")
	if type(current) ~= "table" then
		return
	end
	for device, _ in pairs(current) do
		noctalia.runAsync(stopCmd(device))
	end
	noctalia.state.set("active", {})
end

-- ---------------------------------------------------------------------------
-- startup
-- ---------------------------------------------------------------------------

local startupActive = loadActive()
local startupMode = noctalia.getConfig("on_startup")
if startupMode == nil or startupMode == "" then
	startupMode = "restore"
end

if startupMode == "clear" then
	startupActive = {}
	saveActive(startupActive)
elseif startupMode == "stop_all" then
	for device, _ in pairs(startupActive) do
		noctalia.runAsync(stopCmd(device))
	end
	startupActive = {}
	saveActive(startupActive)
end

dbg("=== service VM loaded (v" .. PLUGIN_VERSION .. ") mode=" .. tostring(startupMode) .. " ===")
dbg("presets root: " .. presetsRoot())
dbg("plugin dir:   " .. tostring(noctalia.pluginDir()))
dbg("data dir:     " .. tostring(noctalia.pluginDataDir()))

noctalia.state.set("active", startupActive)
publishDevices()
checkDaemon()

-- ---------------------------------------------------------------------------
-- watches
-- ---------------------------------------------------------------------------

noctalia.state.watch("active", function(value)
	if type(value) == "table" then
		saveActive(value)
	end
end)

-- The panel bumps this to ask for an immediate rescan (Reload button / open).
noctalia.state.watch("scan_request", function(_value)
	lastDevicesJson = nil
	publishDevices()
	checkDaemon()
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
end

function onConfigChanged()
	lastDevicesJson = nil
	lastDaemonOk = nil
	publishDevices()
	checkDaemon()
end

-- noctalia msg plugin haru/input-remapper:service all reload
-- noctalia msg plugin haru/input-remapper:service all stop-all
function onIpc(event, _payload)
	if event == "reload" then
		lastDevicesJson = nil
		publishDevices()
		checkDaemon()
	elseif event == "stop-all" then
		stopAll()
	end
end

function onExit(signal, reason)
	dbg("onExit signal=" .. tostring(signal) .. " reason=" .. tostring(reason))
end
