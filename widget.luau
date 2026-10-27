-- haru/input-remapper : widget.luau
--
-- Bar indicator. Left click toggles the panel, right click stops every running
-- injection at once (the "stopping is a hassle" complaint this plugin exists
-- to fix). All state comes from the service via noctalia.state.
--
-- While ds4kbm (keyboard + mouse mode) is on, the glyph turns into a gamepad
-- so it is obvious the controller is not a controller right now.

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
local daemon = noctalia.state.get("daemon") or "unknown"
local ds4kbm = noctalia.state.get("ds4kbm") or {}

local function render()
	local count = 0
	local lastPreset = nil
	local lines = {}

	for device, preset in pairs(active) do
		count = count + 1
		lastPreset = preset
		table.insert(lines, noctalia.string.trim(device) .. "  ->  " .. preset)
	end
	table.sort(lines)

	local kbm = ds4kbm.state == "on"
	if kbm then
		table.insert(lines, 1, noctalia.string.trim(ds4kbm.device or "?") .. "  ->  " .. noctalia.tr("widget.kbm_line"))
	end

	-- ds4kbm does not need the daemon, so it still gets its own look below.
	if daemon == "down" and not kbm then
		barWidget.setGlyph("keyboard-off")
		barWidget.setGlyphColor("error")
		barWidget.setColor("error")
		barWidget.setText("")
		barWidget.setTooltip(noctalia.tr("widget.daemon_down"))
		return
	end

	barWidget.setGlyph(kbm and "device-gamepad-2" or "keyboard")

	local accent = (count > 0 or kbm) and "primary" or "on_surface"
	barWidget.setGlyphColor(accent)
	barWidget.setColor(accent)

	local text = ""
	if count == 1 and showLabel then
		text = truncate(lastPreset, maxChars)
	elseif count > 1 then
		text = tostring(count)
	elseif kbm and showLabel then
		text = noctalia.tr("widget.kbm_label")
	end
	barWidget.setText(text)

	if #lines == 0 then
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
	local stopped = 0
	for device, _ in pairs(active) do
		stopped = stopped + 1
		noctalia.runAsync(controlCmd() .. " --command stop --device " .. shq(device))
	end

	if stopped == 0 then
		return
	end

	noctalia.state.set("active", {})
	noctalia.notify(noctalia.tr("panel.title"), noctalia.trp("notify.stopped_all", stopped))
end

function onIpc(event, _payload)
	if event == "toggle" then
		noctalia.togglePanel(PANEL_ID)
	end
end
