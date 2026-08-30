-- haru/input-remapper : widget.luau
--
-- Bar indicator. Left click toggles the panel, right click stops every running
-- injection at once (the "stopping is a hassle" complaint this plugin exists
-- to fix). All state comes from the service via noctalia.state.

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

local function render()
	local count = 0
	local lastPreset = nil
	local lines = {}

	for device, preset in pairs(active) do
		count = count + 1
		lastPreset = preset
		table.insert(lines, noctalia.string.trim(device) .. "  ->  " .. preset)
	end

	if daemon == "down" then
		barWidget.setGlyph("keyboard-off")
		barWidget.setGlyphColor("error")
		barWidget.setColor("error")
		barWidget.setText("")
		barWidget.setTooltip(noctalia.tr("widget.daemon_down"))
		return
	end

	barWidget.setGlyph("keyboard")

	local accent = count > 0 and "primary" or "on_surface"
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
		table.sort(lines)
		barWidget.setTooltip(noctalia.tr("widget.tooltip_title") .. "\n" .. table.concat(lines, "\n"))
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
