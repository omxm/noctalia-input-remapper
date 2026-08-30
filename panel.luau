-- haru/input-remapper : panel.luau
--
-- The pop-up surface. Reads devices/active/daemon from noctalia.state (the
-- service publishes them), runs input-remapper-control on click, and writes
-- the new active map back to state so the widget and the service follow along.
--
-- 0.3.1 is an INSTRUMENTED build. It writes a debug log to
--   <pluginDataDir>/debug.log
-- and prints its version + VM id in the panel, so the drifting-layout problem
-- can be diagnosed from evidence instead of guesswork.

local PLUGIN_VERSION = "0.4.0"

-- ---------------------------------------------------------------------------
-- instrumentation
-- ---------------------------------------------------------------------------

-- A fresh id per VM load. If two different ids show up in the log while the
-- shell was never restarted, an old entry runtime survived a hot reload and is
-- still painting - which would explain a layout that changes between reloads
-- with no code change.
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
	local line = stamp .. "  panel/" .. VM_ID .. "  " .. message .. "\n"

	local existing = ""
	if noctalia.fileExists(path) then
		existing = noctalia.readFile(path) or ""
	end
	-- No append API, so rewrite with a cap to keep this cheap.
	if #existing > 60000 then
		existing = string.sub(existing, -30000)
	end
	noctalia.writeFile(path, existing .. line)
end

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------

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

local function startCmd(device, preset)
	return controlCmd()
		.. " --command start --device "
		.. shq(device)
		.. " --preset "
		.. shq(preset)
end

local function stopCmd(device)
	return controlCmd() .. " --command stop --device " .. shq(device)
end

local function copyMap(source)
	local out = {}
	if type(source) == "table" then
		for key, value in pairs(source) do
			out[key] = value
		end
	end
	return out
end

local function errorText(result, fallbackKey)
	if result ~= nil then
		local stderr = noctalia.string.trim(result.stderr or "")
		if stderr ~= "" then
			return stderr
		end
		local stdout = noctalia.string.trim(result.stdout or "")
		if stdout ~= "" then
			return stdout
		end
	end
	return noctalia.tr(fallbackKey)
end

-- ---------------------------------------------------------------------------
-- layout
--
-- flexGrow only distributes LEFTOVER space. Through 0.3.x the root column had
-- no height of its own, so it shrank to fit its children, leftover was always
-- zero, and the scroll area silently fell back to taking its content height:
-- tall content pushed the footer off the bottom, and a stale small measurement
-- squashed the list to a sliver. Toggling a section changed the content height,
-- which is why the layout appeared to change at random.
--
-- The fix is to give the root column a real height so leftover exists. The
-- value is read from plugin.toml at runtime rather than hardcoded, so the
-- script and the manifest can never drift apart the way they did in 0.2.x.
-- ---------------------------------------------------------------------------

local ROOT_PADDING = 14
local FALLBACK_PANEL_HEIGHT = 540

local function manifestPanelHeight()
	local dir = noctalia.pluginDir()
	if dir == nil then
		return nil
	end
	local raw = noctalia.readFile(dir .. "/plugin.toml")
	if raw == nil then
		return nil
	end

	-- Isolate the [[panel]] block so a height in another entry cannot match.
	local block = string.match(raw, "%[%[panel%]%](.-)\n%[%[")
	if block == nil then
		block = string.match(raw, "%[%[panel%]%](.*)$")
	end
	if block == nil then
		return nil
	end

	local value = string.match(block, "height%s*=%s*(%d+)")
	if value == nil then
		return nil
	end
	return tonumber(value)
end

local PANEL_HEIGHT = manifestPanelHeight() or FALLBACK_PANEL_HEIGHT

-- Subtract the padding. If the host treats `height` as border-box this simply
-- leaves a small gap at the bottom; it can never overflow, which is the side
-- worth erring on.
local ROOT_HEIGHT = PANEL_HEIGHT - (ROOT_PADDING * 2)

local CARD_FILL = "surface_variant/0.45"
local CARD_RADIUS = 12
local SCROLL_MIN_HEIGHT = 80

-- ---------------------------------------------------------------------------
-- state
-- ---------------------------------------------------------------------------

local isOpen = false
local devices = noctalia.state.get("devices") or {}
local active = copyMap(noctalia.state.get("active"))
local daemon = noctalia.state.get("daemon") or "unknown"

local selected = {}
local busy = {}
local sectionOpen = { connected = true, saved = false }

local renderCount = 0
local ticksSinceOpen = 0
local openCount = 0

local render -- forward declaration

local function requestScan()
	noctalia.state.set("scan_request", noctalia.nowMs())
end

local function publishActive()
	noctalia.state.set("active", active)
end

-- ---------------------------------------------------------------------------
-- actions
-- ---------------------------------------------------------------------------

local function startPreset(device, preset)
	if busy[device] then
		return
	end
	busy[device] = true
	render()

	noctalia.runAsync(startCmd(device, preset), function(result)
		busy[device] = nil
		if result ~= nil and result.exitCode == 0 then
			selected[device] = preset
			active[device] = preset
			publishActive()
			dbg("started " .. device .. " -> " .. preset)
		else
			local code = "nil"
			if result ~= nil then
				code = tostring(result.exitCode)
			end
			dbg("START FAILED " .. device .. " -> " .. preset .. " exit=" .. code)
			noctalia.notifyError(
				noctalia.tr("notify.start_failed"),
				errorText(result, "notify.generic_body")
			)
		end
		render()
	end)
end

local function stopDevice(device)
	if busy[device] then
		return
	end
	busy[device] = true
	render()

	noctalia.runAsync(stopCmd(device), function(result)
		busy[device] = nil
		if result ~= nil and result.exitCode == 0 then
			active[device] = nil
			publishActive()
			dbg("stopped " .. device)
		else
			dbg("STOP FAILED " .. device)
			noctalia.notifyError(
				noctalia.tr("notify.stop_failed"),
				errorText(result, "notify.generic_body")
			)
		end
		render()
	end)
end

local function onPresetClicked(device, preset)
	if active[device] == preset then
		stopDevice(device)
	else
		startPreset(device, preset)
	end
end

local function onDeviceButtonClicked(deviceEntry)
	local device = deviceEntry.name
	if active[device] ~= nil then
		stopDevice(device)
		return
	end
	local preset = selected[device] or deviceEntry.presets[1]
	if preset ~= nil then
		startPreset(device, preset)
	end
end

local function stopEverything()
	local any = false
	for device, _ in pairs(active) do
		any = true
		noctalia.runAsync(stopCmd(device))
	end
	if any then
		active = {}
		publishActive()
	end
	render()
end

-- ---------------------------------------------------------------------------
-- grouping
-- ---------------------------------------------------------------------------

local function splitDevices()
	local connected, saved = {}, {}
	for _, entry in ipairs(devices) do
		local isConnected = entry.connected
		if isConnected == nil then
			isConnected = true
		end
		if active[entry.name] ~= nil then
			isConnected = true
		end

		if isConnected then
			table.insert(connected, entry)
		else
			table.insert(saved, entry)
		end
	end
	return connected, saved
end

-- ---------------------------------------------------------------------------
-- rendering
-- ---------------------------------------------------------------------------

local function header()
	return ui.row({ gap = 6, align = "center" }, {
		ui.glyph({ name = "keyboard", size = 17, color = "primary" }),
		ui.label({
			text = noctalia.tr("panel.title"),
			fontSize = 15,
			fontWeight = "bold",
			flexGrow = 1,
			maxLines = 1,
		}),
		ui.button({
			glyph = "settings",
			glyphSize = 14,
			variant = "ghost",
			controlSize = "sm",
			tooltip = noctalia.tr("panel.settings"),
			onClick = function()
				noctalia.openSettings()
			end,
		}),
		ui.button({
			glyph = "x",
			glyphSize = 14,
			variant = "ghost",
			controlSize = "sm",
			tooltip = noctalia.tr("panel.close"),
			onClick = function()
				panel.close()
			end,
		}),
	})
end

local function statusCard()
	local ok = daemon == "ok"
	local debugOn = noctalia.getConfig("debug_log") ~= false

	local madeByRow = {
		ui.label({
			text = noctalia.tr("panel.made_by"),
			fontSize = 10,
			color = "on_surface_variant",
			flexGrow = 1,
		}),
	}
	if debugOn then
		-- Diagnostic stamp: which build, which VM, how many paints. Kept
		-- behind the same toggle as the log file itself, so a normal user
		-- never sees debug scaffolding once things are working.
		table.insert(madeByRow, ui.label({
			text = "v" .. PLUGIN_VERSION .. " " .. VM_ID .. " #" .. tostring(renderCount),
			fontSize = 9,
			color = "on_surface_variant",
		}))
	end

	return ui.column({
		gap = 2,
		padding = 10,
		radius = CARD_RADIUS,
		fill = CARD_FILL,
		border = ok and "outline" or "error",
		borderWidth = 1,
	}, {
		ui.row({ gap = 7, align = "center" }, {
			ui.glyph({
				name = ok and "circle-filled" or "alert-circle",
				size = 10,
				color = ok and "primary" or "error",
			}),
			ui.label({
				text = ok and noctalia.tr("panel.daemon_ok") or noctalia.tr("panel.daemon_down"),
				fontSize = 12,
				color = ok and "on_surface" or "error",
				flexGrow = 1,
				maxLines = 1,
			}),
		}),
		ui.row({ paddingH = 17, gap = 6, align = "center" }, madeByRow),
	})
end

local function sectionHeader(sectionKey, titleKey, count)
	local open = sectionOpen[sectionKey] == true
	return ui.row({
		key = "section-" .. sectionKey,
		gap = 6,
		align = "center",
		paddingH = 4,
		paddingV = 4,
		radius = 8,
		onClick = function()
			sectionOpen[sectionKey] = not open
			dbg("section " .. sectionKey .. " -> " .. tostring(not open))
			render()
		end,
	}, {
		ui.glyph({
			name = open and "chevron-down" or "chevron-right",
			size = 13,
			color = "on_surface_variant",
		}),
		ui.label({
			text = noctalia.tr(titleKey),
			fontSize = 11,
			fontWeight = "bold",
			color = "on_surface_variant",
			flexGrow = 1,
			maxLines = 1,
		}),
		ui.label({
			text = tostring(count),
			fontSize = 11,
			color = "on_surface_variant",
		}),
	})
end

local function presetRow(deviceEntry, preset)
	local device = deviceEntry.name
	local isActive = active[device] == preset

	local children = {
		ui.glyph({
			name = isActive and "circle-filled" or "circle",
			size = 11,
			color = isActive and "primary" or "on_surface_variant",
		}),
		ui.label({
			text = preset,
			fontSize = 12,
			color = isActive and "primary" or "on_surface",
			flexGrow = 1,
			maxLines = 1,
		}),
	}

	if isActive then
		table.insert(children, ui.label({
			text = noctalia.tr("panel.setted"),
			fontSize = 10,
			fontWeight = "bold",
			color = "primary",
		}))
	end

	return ui.row({
		-- Key is derived only from identity, never from position, so folding a
		-- section cannot renumber a row and confuse the reconciler.
		key = "preset:" .. device .. ":" .. preset,
		gap = 8,
		align = "center",
		paddingH = 7,
		paddingV = 5,
		radius = 8,
		fill = isActive and "primary/0.16" or nil,
		onClick = function()
			onPresetClicked(device, preset)
		end,
	}, children)
end

local function deviceCard(deviceEntry, dimmed)
	local device = deviceEntry.name
	local isActive = active[device] ~= nil
	local isBusy = busy[device] == true

	local rows = {
		ui.row({ gap = 8, align = "center" }, {
			ui.label({
				text = deviceEntry.display,
				fontSize = 13,
				fontWeight = "bold",
				color = isActive and "primary" or "on_surface",
				flexGrow = 1,
				maxLines = 1,
			}),
			ui.button({
				text = isBusy and noctalia.tr("panel.working")
					or (isActive and noctalia.tr("panel.stop") or noctalia.tr("panel.start")),
				fontSize = 11,
				variant = isActive and "destructive" or "primary",
				controlSize = "sm",
				enabled = not isBusy and #deviceEntry.presets > 0,
				onClick = function()
					onDeviceButtonClicked(deviceEntry)
				end,
			}),
		}),
	}

	if #deviceEntry.presets == 0 then
		table.insert(rows, ui.row({ paddingH = 7, paddingV = 4 }, {
			ui.label({
				text = noctalia.tr("panel.no_presets"),
				fontSize = 11,
				color = "on_surface_variant",
			}),
		}))
	else
		for _, preset in ipairs(deviceEntry.presets) do
			table.insert(rows, presetRow(deviceEntry, preset))
		end
	end

	return ui.column({
		key = "device:" .. device,
		gap = 3,
		padding = 10,
		radius = CARD_RADIUS,
		fill = CARD_FILL,
		border = isActive and "primary" or "outline",
		borderWidth = 1,
		opacity = dimmed and 0.6 or nil,
	}, rows)
end

local function noticeCard(textKey)
	return ui.column({
		padding = 12,
		radius = CARD_RADIUS,
		fill = CARD_FILL,
		border = "outline",
		borderWidth = 1,
	}, {
		ui.label({
			text = noctalia.tr(textKey),
			fontSize = 11,
			color = "on_surface_variant",
			maxLines = 4,
		}),
	})
end

local function emptyState()
	return ui.column({ gap = 8, paddingV = 24, align = "center" }, {
		ui.glyph({ name = "folder-off", size = 24, color = "on_surface_variant" }),
		ui.label({
			text = noctalia.tr("panel.no_devices"),
			fontSize = 12,
			color = "on_surface_variant",
			textAlign = "center",
		}),
		ui.label({
			text = noctalia.tr("panel.no_devices_hint"),
			fontSize = 10,
			color = "on_surface_variant",
			textAlign = "center",
			maxLines = 4,
		}),
	})
end

local function footer()
	return ui.row({ gap = 8 }, {
		ui.button({
			glyph = "refresh",
			glyphSize = 13,
			text = noctalia.tr("panel.reload"),
			fontSize = 11,
			variant = "ghost",
			controlSize = "sm",
			flexGrow = 1,
			onClick = function()
				dbg("reload clicked")
				requestScan()
			end,
		}),
		ui.button({
			glyph = "player-stop",
			glyphSize = 13,
			text = noctalia.tr("panel.stop_all"),
			fontSize = 11,
			variant = "ghost",
			controlSize = "sm",
			flexGrow = 1,
			enabled = next(active) ~= nil,
			onClick = function()
				stopEverything()
			end,
		}),
	})
end

local function body()
	if #devices == 0 then
		return emptyState()
	end

	local connected, saved = splitDevices()
	local blocks = {}

	table.insert(blocks, sectionHeader("connected", "panel.section_connected", #connected))
	if sectionOpen.connected then
		if #connected == 0 then
			table.insert(blocks, noticeCard("panel.none_connected"))
		else
			for _, entry in ipairs(connected) do
				table.insert(blocks, deviceCard(entry, false))
			end
		end
	end

	if #saved > 0 then
		table.insert(blocks, sectionHeader("saved", "panel.section_saved", #saved))
		if sectionOpen.saved then
			for _, entry in ipairs(saved) do
				table.insert(blocks, deviceCard(entry, true))
			end
		end
	end

	return ui.column({ gap = 8 }, blocks)
end

local function scrollArea()
	local override = noctalia.getConfig("scroll_height")
	if type(override) == "number" and override > 0 then
		return ui.scroll({ height = override }, { body() }), "fixed:" .. tostring(override)
	end
	return ui.scroll({ flexGrow = 1, minHeight = SCROLL_MIN_HEIGHT }, { body() }), "auto"
end

local lastSignature = nil

render = function(force)
	if not isOpen then
		return
	end

	local signature = noctalia.json.encode({
		devices = devices,
		active = active,
		daemon = daemon,
		busy = busy,
		sections = sectionOpen,
		selected = selected,
	})

	-- Never dedup during the settling window right after an open: the surface
	-- may not have its final size on the first paint, and skipping the repaint
	-- would freeze a layout that was measured too early.
	local settling = ticksSinceOpen < 3

	if not force and not settling and signature ~= nil and signature == lastSignature then
		return
	end
	lastSignature = signature

	renderCount = renderCount + 1
	local tree, scrollMode = scrollArea()

	dbg(
		"render #"
			.. tostring(renderCount)
			.. " force="
			.. tostring(force == true)
			.. " tick="
			.. tostring(ticksSinceOpen)
			.. " scroll="
			.. scrollMode
			.. " devices="
			.. tostring(#devices)
			.. " conn="
			.. tostring(sectionOpen.connected)
			.. " saved="
			.. tostring(sectionOpen.saved)
	)

	panel.render(ui.column({
		gap = 10,
		padding = ROOT_PADDING,
		-- The whole point: a real height here is what creates the leftover
		-- space that the scroll area's flexGrow claims. Without it the footer
		-- gets pushed off the surface as soon as the list grows.
		height = ROOT_HEIGHT,
	}, {
		header(),
		statusCard(),
		ui.separator({ spacing = 1 }),
		tree,
		footer(),
	}))
end

-- ---------------------------------------------------------------------------
-- watches
-- ---------------------------------------------------------------------------

noctalia.state.watch("devices", function(value)
	if type(value) == "table" then
		devices = value
	end
	render()
end)

noctalia.state.watch("active", function(value)
	active = copyMap(value)
	render()
end)

noctalia.state.watch("daemon", function(value)
	daemon = value or "unknown"
	render()
end)

-- ---------------------------------------------------------------------------
-- lifecycle
-- ---------------------------------------------------------------------------

dbg(
	"=== panel VM loaded (v"
		.. PLUGIN_VERSION
		.. ") panelHeight="
		.. tostring(PANEL_HEIGHT)
		.. (manifestPanelHeight() == nil and " (FALLBACK)" or " (from manifest)")
		.. " rootHeight="
		.. tostring(ROOT_HEIGHT)
		.. " ==="
)

function onOpen(_context)
	isOpen = true
	openCount = openCount + 1
	ticksSinceOpen = 0
	lastSignature = nil

	devices = noctalia.state.get("devices") or devices
	active = copyMap(noctalia.state.get("active"))
	daemon = noctalia.state.get("daemon") or daemon

	-- Root cause of the 0.2.x/0.3.0/0.3.1 "flip-flopping look": sectionOpen
	-- used to persist across close/open. Whatever it was last toggled to (by
	-- a click, including ones made while troubleshooting) silently carried
	-- forward forever, so the panel could open fully collapsed and look
	-- broken with no version change and no double-loaded VM involved at all -
	-- confirmed by VM_ID staying constant across the whole debug.log. Haru's
	-- original spec was "start collapsed", meaning every open, not "collapse
	-- once and remember it". Reset on every open instead.
	sectionOpen = { connected = true, saved = false }

	panel.setWantsSecondTicks(true)

	dbg("onOpen #" .. tostring(openCount))
	requestScan()
	render(true)
end

-- Repaint a couple of times right after opening. If the very first paint was
-- laid out against a surface that had not reached its final size, the retained
-- tree would otherwise keep that stale geometry for the whole session.
function update()
	if not isOpen then
		return
	end
	ticksSinceOpen = ticksSinceOpen + 1
	if ticksSinceOpen <= 2 then
		dbg("settle tick " .. tostring(ticksSinceOpen))
		render(true)
	elseif ticksSinceOpen == 3 then
		panel.setWantsSecondTicks(false)
		dbg("settled, ticks off")
	end
end

function onClose()
	isOpen = false
	lastSignature = nil
	panel.setWantsSecondTicks(false)
	dbg("onClose (renders so far: " .. tostring(renderCount) .. ")")
end

function onExit(signal, reason)
	dbg("onExit signal=" .. tostring(signal) .. " reason=" .. tostring(reason))
end
