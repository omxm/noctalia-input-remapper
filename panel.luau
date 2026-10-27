-- haru/input-remapper : panel.luau
--
-- The pop-up surface. Reads devices/active/running/daemon/modes/ds4kbm/
-- kbm_analysis from noctalia.state (the service publishes them), runs
-- input-remapper-control or ds4kbm-ctl on click, and writes `active` (what we
-- asked for) / `modes` back to state so the widget and the service follow
-- along. What is shown as running comes from `running`, which the service
-- reads from the daemon over D-Bus.
--
-- Gamepads can run a preset in one of two ways ("games see it as"):
--   controller        input-remapper injects the preset as usual
--   keyboard & mouse  ds4kbm grabs the controller and runs the same preset,
--                     exposing only a keyboard and a pointer to games
--
-- With debug_log on it writes <pluginDataDir>/debug.log and prints its
-- version + VM id in the footer.

local PLUGIN_VERSION = "0.6.0"

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

local function presetsRoot()
	local dir = noctalia.getConfig("config_dir")
	if dir == nil or dir == "" then
		dir = "~/.config/input-remapper-2"
	end
	return noctalia.expandPath(dir) .. "/presets"
end

-- ds4kbm/ds4kbm-ctl, see service.luau for why the control command is passed.
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
-- the copy in service.luau.
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
-- The reconciler keeps a prop's old value when it is omitted, so props that
-- toggle get an explicit "off" value instead of nil.
local NO_FILL = "surface_variant/0"
local function noop() end
local CARD_RADIUS = 12
local ROW_RADIUS = 8
local SCROLL_MIN_HEIGHT = 80

-- ---------------------------------------------------------------------------
-- state
-- ---------------------------------------------------------------------------

local isOpen = false
local devices = noctalia.state.get("devices") or {}
local active = copyMap(noctalia.state.get("active"))
local running = copyMap(noctalia.state.get("running"))
local daemon = noctalia.state.get("daemon") or "unknown"
local modes = copyMap(noctalia.state.get("modes"))
local ds4kbm = noctalia.state.get("ds4kbm") or {}
local kbmAnalysis = noctalia.state.get("kbm_analysis") or {}

-- device -> preset being started/stopped (or true), while a command runs
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

local function kbmRunning(device)
	return ds4kbm.state == "on" and ds4kbm.device == device
end

-- The preset running on a device and how ("controller" / "kbm"), or nil.
-- The preset is "" when input-remapper runs one this plugin did not start
-- (the daemon reports that something runs, not what).
local function runningPreset(device)
	if kbmRunning(device) then
		return ds4kbm.preset, "kbm"
	end
	if running[device] ~= nil then
		return running[device], "controller"
	end
	return nil, nil
end

-- What actually runs wins over the remembered choice, so the switch never
-- disagrees with the card (e.g. ds4kbm started from a terminal).
local function modeOf(entry)
	if not entry.gamepad then
		return "controller"
	end
	local _, running = runningPreset(entry.name)
	if running ~= nil then
		return running
	end
	return modes[entry.name] == "kbm" and "kbm" or "controller"
end

-- { usable, skipped } for a preset in keyboard & mouse mode, or nil while
-- the service has not analyzed it yet.
local function kbmInfo(device, preset)
	local perDevice = kbmAnalysis[device]
	if type(perDevice) ~= "table" then
		return nil
	end
	return perDevice[preset]
end

local function kbmUsable(device, preset)
	local info = kbmInfo(device, preset)
	return info == nil or (info.usable or 0) > 0
end

-- ---------------------------------------------------------------------------
-- actions
-- ---------------------------------------------------------------------------

local function finish(device)
	busy[device] = nil
	requestScan()
	render()
end

local function runStart(device, preset)
	noctalia.runAsync(startCmd(device, preset), function(result)
		if result ~= nil and result.exitCode == 0 then
			active[device] = preset
			publishActive()
			dbg("started " .. device .. " -> " .. preset)
		else
			dbg("START FAILED " .. device .. " -> " .. preset .. " exit=" .. tostring(result and result.exitCode))
			noctalia.notifyError(noctalia.tr("notify.start_failed"), errorText(result, "notify.generic_body"))
		end
		finish(device)
	end)
end

-- Never run both at once: ds4kbm holds an exclusive grab on the controller,
-- so it has to let go before input-remapper can inject, and ds4kbm-ctl start
-- stops input-remapper's injection for the device itself.
local function startController(device, preset)
	if kbmRunning(device) then
		noctalia.runAsync(ds4kbmCmd("stop"), function(_result)
			dbg("ds4kbm stopped before starting " .. device .. " -> " .. preset)
			runStart(device, preset)
		end)
	else
		runStart(device, preset)
	end
end

local function startKbm(device, preset)
	local path = presetsRoot() .. "/" .. device .. "/" .. preset .. ".json"
	noctalia.runAsync(ds4kbmCmd("start " .. shq(path) .. ds4kbmArgs()), function(result)
		if result ~= nil and result.exitCode == 0 then
			dbg("ds4kbm started " .. device .. " -> " .. preset)
			if active[device] ~= nil then
				active[device] = nil
				publishActive()
			end
		else
			dbg("DS4KBM START FAILED " .. device .. " -> " .. preset)
			noctalia.notifyError(noctalia.tr("notify.kbm_start_failed"), errorText(result, "notify.kbm_generic_body"))
		end
		finish(device)
	end)
end

local function stopRunning(device)
	if kbmRunning(device) then
		noctalia.runAsync(ds4kbmCmd("stop"), function(result)
			if result == nil or result.exitCode ~= 0 then
				noctalia.notifyError(noctalia.tr("notify.kbm_stop_failed"), errorText(result, "notify.kbm_generic_body"))
			end
			dbg("ds4kbm stopped " .. device)
			finish(device)
		end)
		return
	end

	noctalia.runAsync(stopCmd(device), function(result)
		if result ~= nil and result.exitCode == 0 then
			active[device] = nil
			publishActive()
			dbg("stopped " .. device)
		else
			dbg("STOP FAILED " .. device)
			noctalia.notifyError(noctalia.tr("notify.stop_failed"), errorText(result, "notify.generic_body"))
		end
		finish(device)
	end)
end

-- Run `preset` on `device` in `mode`, replacing whatever runs there now.
local function startIn(device, preset, mode)
	busy[device] = preset
	render()
	if mode == "kbm" then
		startKbm(device, preset)
	else
		startController(device, preset)
	end
end

local function onPresetClicked(entry, preset)
	local device = entry.name
	if busy[device] ~= nil then
		return
	end
	local mode = modeOf(entry)
	local current, currentMode = runningPreset(device)

	if current == preset and currentMode == mode then
		busy[device] = preset
		render()
		stopRunning(device)
	elseif mode == "kbm" and not kbmUsable(device, preset) then
		return
	else
		startIn(device, preset, mode)
	end
end

local function onStopClicked(entry)
	local device = entry.name
	if busy[device] ~= nil then
		return
	end
	busy[device] = true
	render()
	stopRunning(device)
end

-- Switching while a preset runs moves that preset over to the new mode.
local function setMode(entry, mode)
	local device = entry.name
	if busy[device] ~= nil or modeOf(entry) == mode then
		return
	end
	modes[device] = (mode == "kbm") and "kbm" or nil
	noctalia.state.set("modes", modes)
	dbg("mode " .. device .. " -> " .. mode)

	local current = runningPreset(device)
	if current == nil or current == "" then
		-- Nothing to move over (or nothing we know the name of).
		render()
	elseif mode == "kbm" and not kbmUsable(device, current) then
		busy[device] = true
		render()
		stopRunning(device)
	else
		startIn(device, current, mode)
	end
end

local function stopEverything()
	local targets = {}
	for device, _ in pairs(active) do
		targets[device] = true
	end
	for device, _ in pairs(running) do
		targets[device] = true
	end
	local any = false
	for device, _ in pairs(targets) do
		any = true
		noctalia.runAsync(stopCmd(device))
	end
	if any then
		active = {}
		publishActive()
		requestScan()
	end
	if ds4kbm.state == "on" then
		noctalia.runAsync(ds4kbmCmd("stop"), function(_result)
			requestScan()
		end)
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
		if runningPreset(entry.name) ~= nil then
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

local function iconButton(glyph, tooltipKey, onClick)
	return ui.button({
		glyph = glyph,
		glyphSize = 15,
		variant = "ghost",
		controlSize = "sm",
		tooltip = noctalia.tr(tooltipKey),
		onClick = onClick,
	})
end

local function header()
	local ok = daemon == "ok"
	return ui.row({ gap = 10, align = "center" }, {
		ui.glyph({ name = "keyboard", size = 20, color = "primary" }),
		ui.column({ gap = 1, flexGrow = 1 }, {
			ui.label({
				text = noctalia.tr("panel.title"),
				fontSize = 15,
				fontWeight = "bold",
				maxLines = 1,
			}),
			ui.row({ gap = 5, align = "center" }, {
				ui.glyph({ name = "circle-filled", size = 7, color = ok and "primary" or "error" }),
				ui.label({
					text = ok and noctalia.tr("panel.daemon_ok") or noctalia.tr("panel.daemon_down"),
					fontSize = 11,
					color = ok and "on_surface_variant" or "error",
					maxLines = 1,
				}),
			}),
		}),
		iconButton("refresh", "panel.reload", function()
			dbg("reload clicked")
			requestScan()
		end),
		iconButton("settings", "panel.settings", function()
			noctalia.openSettings()
		end),
		iconButton("x", "panel.close", function()
			panel.close()
		end),
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
		radius = ROW_RADIUS,
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
			fontWeight = "bold",
			color = "on_surface_variant",
		}),
	})
end

local function stopButton(entry)
	local isBusy = busy[entry.name] ~= nil
	return ui.row({
		key = "stop:" .. entry.name,
		gap = 6,
		align = "center",
		paddingH = 12,
		paddingV = 6,
		radius = ROW_RADIUS,
		border = "error",
		borderWidth = 1,
		onClick = (not isBusy) and function()
			onStopClicked(entry)
		end or noop,
	}, {
		ui.glyph({ name = "player-stop-filled", size = 10, color = "error" }),
		ui.label({
			text = isBusy and noctalia.tr("panel.working") or noctalia.tr("panel.stop"),
			fontSize = 12,
			fontWeight = "bold",
			color = "error",
		}),
	})
end

local function modeSegment(entry, mode, glyph, textKey)
	local selected = modeOf(entry) == mode
	local onPrimary = selected and mode == "kbm"
	local color = onPrimary and "on_primary" or (selected and "on_surface" or "on_surface_variant")
	local fill = NO_FILL
	if selected then
		fill = (mode == "kbm") and "primary" or "on_surface/0.12"
	end
	return ui.row({
		key = "mode:" .. entry.name .. ":" .. mode,
		gap = 7,
		align = "center",
		justify = "center",
		flexGrow = 1,
		paddingV = 7,
		radius = ROW_RADIUS,
		fill = fill,
		onClick = function()
			setMode(entry, mode)
		end,
	}, {
		ui.glyph({ name = glyph, size = 14, color = color }),
		ui.label({
			text = noctalia.tr(textKey),
			fontSize = 12,
			fontWeight = "bold",
			color = color,
			maxLines = 1,
		}),
	})
end

local function modeSwitch(entry)
	local rows = {
		ui.label({
			text = noctalia.tr("panel.games_see"),
			fontSize = 10,
			fontWeight = "bold",
			color = "on_surface_variant",
		}),
		ui.row({
			gap = 4,
			padding = 3,
			radius = ROW_RADIUS + 2,
			border = "outline",
			borderWidth = 1,
		}, {
			modeSegment(entry, "controller", "device-gamepad-2", "panel.mode_controller"),
			modeSegment(entry, "kbm", "mouse", "panel.mode_kbm"),
		}),
	}

	if modeOf(entry) == "kbm" then
		table.insert(rows, ui.row({ gap = 8, align = "center" }, {
			ui.label({
				text = noctalia.tr("panel.kbm_hint"),
				fontSize = 11,
				color = "on_surface_variant",
				flexGrow = 1,
				maxLines = 3,
			}),
			ui.row({
				paddingH = 6,
				paddingV = 4,
				radius = ROW_RADIUS,
				onClick = function()
					noctalia.openSettings()
				end,
			}, {
				ui.label({
					text = noctalia.tr("panel.tune"),
					fontSize = 12,
					fontWeight = "bold",
					color = "primary",
				}),
			}),
		}))
	end

	return ui.column({ gap = 6 }, rows)
end

local function presetRow(entry, preset)
	local device = entry.name
	local mode = modeOf(entry)
	local current, currentMode = runningPreset(device)
	local isRunning = current == preset and currentMode == mode
	local isBusy = busy[device] ~= nil

	-- In keyboard & mouse mode, say how much of the preset ds4kbm can't do.
	local note = nil
	local usable = true
	if mode == "kbm" then
		local info = kbmInfo(device, preset)
		usable = kbmUsable(device, preset)
		if not usable then
			note = noctalia.tr("panel.kbm_unusable")
		elseif info ~= nil and (info.skipped or 0) > 0 then
			note = noctalia.trp("panel.kbm_skipped", info.skipped)
		end
	end

	local text = {
		ui.label({
			text = preset,
			fontSize = 13,
			fontWeight = "bold",
			color = isRunning and "primary" or "on_surface",
			maxLines = 1,
		}),
	}
	if note ~= nil then
		table.insert(text, ui.label({
			text = note,
			fontSize = 10,
			color = "on_surface_variant",
			maxLines = 2,
		}))
	end

	local trailing
	if busy[device] == preset then
		trailing = ui.label({ text = noctalia.tr("panel.working"), fontSize = 11, color = "on_surface_variant" })
	elseif isRunning then
		trailing = ui.label({
			text = noctalia.tr("panel.active"),
			fontSize = 10,
			fontWeight = "bold",
			color = "primary",
		})
	else
		trailing = ui.glyph({ name = "player-play-filled", size = 9, color = "on_surface_variant" })
	end

	local clickable = usable and not isBusy
	return ui.row({
		-- Key is derived only from identity, never from position, so folding a
		-- section cannot renumber a row and confuse the reconciler.
		key = "preset:" .. device .. ":" .. preset,
		gap = 10,
		align = "center",
		paddingH = 10,
		paddingV = 7,
		radius = ROW_RADIUS,
		fill = isRunning and "primary/0.16" or NO_FILL,
		opacity = usable and 1 or 0.4,
		onClick = clickable and function()
			onPresetClicked(entry, preset)
		end or noop,
	}, {
		ui.glyph({
			name = isRunning and "circle-dot" or "circle",
			size = 13,
			color = isRunning and "primary" or "on_surface_variant",
		}),
		ui.column({ gap = 1, flexGrow = 1 }, text),
		trailing,
	})
end

local function deviceCard(entry, dimmed)
	local device = entry.name
	local current = runningPreset(device)
	local isRunning = current ~= nil

	local subtitle
	if isRunning and current ~= "" then
		subtitle = noctalia.tr("panel.running") .. " · " .. current
	elseif isRunning then
		subtitle = noctalia.tr("panel.running")
	else
		subtitle = noctalia.trp("panel.preset_count", #entry.presets)
	end

	local titleRow = {
		ui.column({ gap = 2, flexGrow = 1 }, {
			ui.label({
				text = entry.display,
				fontSize = 14,
				fontWeight = "bold",
				color = isRunning and "primary" or "on_surface",
				-- Long names wrap instead of being cut off.
				maxLines = 2,
			}),
			ui.label({
				text = subtitle,
				fontSize = 11,
				color = "on_surface_variant",
				maxLines = 1,
			}),
		}),
	}
	if isRunning then
		table.insert(titleRow, stopButton(entry))
	end

	local rows = { ui.row({ gap = 8, align = "center" }, titleRow) }

	if entry.gamepad then
		table.insert(rows, modeSwitch(entry))
	end

	if #entry.presets == 0 then
		table.insert(rows, ui.row({ paddingH = 10, paddingV = 4 }, {
			ui.label({
				text = noctalia.tr("panel.no_presets"),
				fontSize = 11,
				color = "on_surface_variant",
			}),
		}))
	else
		local list = {}
		for _, preset in ipairs(entry.presets) do
			table.insert(list, presetRow(entry, preset))
		end
		table.insert(rows, ui.column({ gap = 2 }, list))
	end

	return ui.column({
		key = "device:" .. device,
		gap = 8,
		padding = 12,
		radius = CARD_RADIUS,
		fill = CARD_FILL,
		border = isRunning and "primary" or "outline",
		borderWidth = 1,
		opacity = dimmed and 0.6 or 1,
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
	local anything = next(running) ~= nil or next(active) ~= nil or ds4kbm.state == "on"
	local right = {
		ui.label({
			text = noctalia.tr("panel.made_by"),
			fontSize = 10,
			color = "on_surface_variant",
		}),
	}
	if noctalia.getConfig("debug_log") ~= false then
		-- Diagnostic stamp: which build, which VM, how many paints. Kept
		-- behind the same toggle as the log file itself, so a normal user
		-- never sees debug scaffolding once things are working.
		table.insert(right, 1, ui.label({
			text = "v" .. PLUGIN_VERSION .. " " .. VM_ID .. " #" .. tostring(renderCount),
			fontSize = 9,
			color = "on_surface_variant",
		}))
	end

	return ui.row({ gap = 8, align = "center" }, {
		ui.button({
			glyph = "player-stop-filled",
			glyphSize = 12,
			text = noctalia.tr("panel.stop_all"),
			fontSize = 12,
			variant = "ghost",
			controlSize = "sm",
			enabled = anything,
			onClick = function()
				stopEverything()
			end,
		}),
		ui.row({ gap = 8, align = "center", justify = "end", flexGrow = 1 }, right),
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

	return ui.column({ gap = 10 }, blocks)
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

	-- Everything the tree depends on. Anything left out here would let a
	-- state change be skipped as "nothing changed".
	local signature = noctalia.json.encode({
		devices = devices,
		active = active,
		running = running,
		daemon = daemon,
		modes = modes,
		ds4kbm = ds4kbm,
		kbmAnalysis = kbmAnalysis,
		busy = busy,
		sections = sectionOpen,
		debug = noctalia.getConfig("debug_log"),
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
		gap = 12,
		padding = ROOT_PADDING,
		-- The whole point: a real height here is what creates the leftover
		-- space that the scroll area's flexGrow claims. Without it the footer
		-- gets pushed off the surface as soon as the list grows.
		height = ROOT_HEIGHT,
	}, {
		header(),
		tree,
		ui.separator({ spacing = 1 }),
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

noctalia.state.watch("running", function(value)
	running = copyMap(value)
	render()
end)

noctalia.state.watch("daemon", function(value)
	daemon = value or "unknown"
	render()
end)

noctalia.state.watch("modes", function(value)
	modes = copyMap(value)
	render()
end)

noctalia.state.watch("ds4kbm", function(value)
	ds4kbm = (type(value) == "table") and value or {}
	render()
end)

noctalia.state.watch("kbm_analysis", function(value)
	kbmAnalysis = (type(value) == "table") and value or {}
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
	running = copyMap(noctalia.state.get("running"))
	daemon = noctalia.state.get("daemon") or daemon
	modes = copyMap(noctalia.state.get("modes"))
	ds4kbm = noctalia.state.get("ds4kbm") or ds4kbm
	kbmAnalysis = noctalia.state.get("kbm_analysis") or kbmAnalysis

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
