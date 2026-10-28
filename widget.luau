-- haru/input-remapper : widget.luau
--
-- Bar indicator. Left click toggles the panel, right click stops everything
-- that runs - input-remapper injections and ds4kbm alike (the "stopping is a
-- hassle" complaint this plugin exists to fix). All state comes from the
-- service via noctalia.state.
--
--   nothing running            keyboard glyph, muted
--   one preset                 keyboard glyph + preset name
--   several                    keyboard glyph + count
--   controller as kbd & mouse  mouse glyph + preset name
--   daemon down                keyboard-off glyph in error color

local PANEL_ID = "haru/input-remapper:panel"

local function shq(value)
	local escaped = string.gsub(tostring(value), "'", "'\\''")
	return "'" .. escaped .. "'"
end

local function controlCmd()
	local cmd = noctalia.getConfig("control_cmd")
	if cmd == nil or cmd == "" then
		return "input-remapper-control"
	end
	return cmd
end

local function ds4kbmCmd(sub)
	local dir = noctalia.pluginDir() or "."
	return "DS4KBM_REMAPPER_CMD="
		.. shq(controlCmd())
		.. " "
		.. shq(dir .. "/ds4kbm/ds4kbm-ctl")
		.. " "
		.. sub
end

-- See revealPrefix in service.luau: input-remapper-control cannot find a
-- hidden controller, so make it visible first.
local HIDE_HELPER = "/usr/local/bin/noctalia-padhide"

local function revealPrefix(device)
	local hide = noctalia.state.get("pad_hide")
	if type(hide) == "table" and hide[device] ~= nil then
		return "sudo -n " .. HIDE_HELPER .. " show " .. shq(device) .. " >/dev/null 2>&1; "
	end
	return ""
end

local function holdHiding(device, on)
	local hold = {}
	local current = noctalia.state.get("hide_hold")
	if type(current) == "table" then
		for key, value in pairs(current) do
			hold[key] = value
		end
	end
	hold[device] = on and noctalia.nowMs() or nil
	noctalia.state.set("hide_hold", hold)
end

local function truncate(text, limit)
	if limit == nil or limit < 4 or #text <= limit then
		return text
	end
	return string.sub(text, 1, limit - 1) .. "…"
end

local showLabel = noctalia.getConfig("show_label")
if showLabel == nil then
	showLabel = true
end

local maxChars = noctalia.getConfig("max_label_chars")
if type(maxChars) ~= "number" then
	maxChars = 18
end

local active = noctalia.state.get("active") or {}
local running = noctalia.state.get("running") or {}
local daemon = noctalia.state.get("daemon") or "unknown"
local ds4kbm = noctalia.state.get("ds4kbm") or {}

local function render()
	local count = 0
	local lastPreset = nil
	local lines = {}

	-- `running` is what the daemon reports; "" means a preset this plugin did
	-- not start, so the device name stands in for it.
	for device, preset in pairs(running) do
		count = count + 1
		lastPreset = (preset ~= "") and preset or noctalia.string.trim(device)
		table.insert(lines, noctalia.string.trim(device) .. "  ->  " .. ((preset ~= "") and preset or "?"))
	end
	table.sort(lines)

	-- ds4kbm does not need the daemon, so it keeps its own look even then.
	local kbm = ds4kbm.state == "on"
	if kbm then
		count = count + 1
		lastPreset = ds4kbm.preset or "?"
		table.insert(lines, 1, noctalia.string.trim(ds4kbm.device or "?") .. "  ->  " .. lastPreset
			.. "  " .. noctalia.tr("widget.kbm_suffix"))
	end

	if daemon == "down" and not kbm then
		barWidget.setGlyph("keyboard-off")
		barWidget.setGlyphColor("error")
		barWidget.setColor("error")
		barWidget.setText("")
		barWidget.setTooltip(noctalia.tr("widget.daemon_down"))
		return
	end

	barWidget.setGlyph(kbm and "mouse" or "keyboard")

	local accent = count > 0 and "primary" or "on_surface_variant"
	barWidget.setGlyphColor(accent)
	barWidget.setColor(accent)

	local text = ""
	if count == 1 and showLabel then
		text = truncate(lastPreset, maxChars)
	elseif count > 1 then
		text = tostring(count)
	end
	barWidget.setText(text)

	if count == 0 then
		barWidget.setTooltip(noctalia.tr("widget.idle"))
	else
		local tooltip = noctalia.tr("widget.tooltip_title") .. "\n" .. table.concat(lines, "\n")
		if daemon == "down" then
			tooltip = tooltip .. "\n" .. noctalia.tr("widget.daemon_down")
		end
		barWidget.setTooltip(tooltip)
	end
end

noctalia.state.watch("active", function(value)
	active = (type(value) == "table") and value or {}
	render()
end)

noctalia.state.watch("running", function(value)
	running = (type(value) == "table") and value or {}
	render()
end)

noctalia.state.watch("daemon", function(value)
	daemon = value or "unknown"
	render()
end)

noctalia.state.watch("ds4kbm", function(value)
	ds4kbm = (type(value) == "table") and value or {}
	render()
end)

function update()
	-- The watches do the real work; this is just a heartbeat so a widget that
	-- loads before the service still lands on a correct first paint.
	noctalia.setUpdateInterval(10000)
	render()
end

function onClick()
	noctalia.togglePanel(PANEL_ID)
end

function onRightClick()
	local targets = {}
	for device, _ in pairs(active) do
		targets[device] = true
	end
	for device, _ in pairs(running) do
		targets[device] = true
	end
	local stopped = 0
	for device, _ in pairs(targets) do
		stopped = stopped + 1
		holdHiding(device, true)
		noctalia.runAsync(revealPrefix(device) .. controlCmd() .. " --command stop --device " .. shq(device), function(_result)
			holdHiding(device, false)
		end)
	end
	if ds4kbm.state == "on" then
		stopped = stopped + 1
		noctalia.runAsync(ds4kbmCmd("stop"), function(_result)
			noctalia.state.set("scan_request", noctalia.nowMs())
		end)
	end

	if stopped == 0 then
		return
	end

	noctalia.state.set("active", {})
	noctalia.state.set("scan_request", noctalia.nowMs())
	noctalia.notify(noctalia.tr("panel.title"), noctalia.trp("notify.stopped_all", stopped))
end

function onIpc(event, _payload)
	if event == "toggle" then
		noctalia.togglePanel(PANEL_ID)
	end
end
