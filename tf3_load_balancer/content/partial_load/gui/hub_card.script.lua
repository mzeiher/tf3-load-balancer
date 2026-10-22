local react = ug_require "::/gui/main/react.lua"
local builtin = ug_require "::/gui/main/builtin.lua"
local engine_react_util = ug_require "::/gui/main/engine_react_util.tl"
local content_card = ug_require "::/gui/main/content_card.tl"
local warehouse_eow = ug_require "::/gui/entity_window/warehouse/warehouse_eow.script.tl"
local hub = ug_require "/partial_load/hub.lua"

local percent = hub.percent

local function text(value, class)
	return builtin.TextView{ meta = class and { class = class } or nil, text = value }
end

local function makeView(warehouse, selectedCargo)
	local state = hub.readState()
	local cargoOptions, known = {}, {}
	for _, group in pairs(state.groups or {}) do
		if group.warehouse == warehouse and not known[group.cargo] then
			known[group.cargo] = true
			cargoOptions[#cargoOptions + 1] = group.cargo
		end
	end
	for _, cargo in ipairs(hub.cargoTypesInStock(warehouse)) do
		if not known[cargo] then
			known[cargo] = true
			cargoOptions[#cargoOptions + 1] = cargo
		end
	end
	table.sort(cargoOptions)

	local cargo = known[selectedCargo] and selectedCargo or cargoOptions[1]
	local view = { cargo = cargo, cargoOptions = cargoOptions, rows = {} }
	if cargo == nil then
		return view
	end

	local group = (state.groups or {})[hub.groupKey(warehouse, cargo)] or {}
	view.enabled = group.enabled == true
	view.stock, view.used, view.capacity = hub.stockUsedAndCapacity(warehouse, cargo)
	view.inflow = group.inflowWindow
	view.overflow = view.enabled and group.overflow == true

	for _, lineStop in ipairs(hub.lineStops(warehouse)) do
		local entry = (group.lines or {})[tostring(lineStop.line)] or {}
		view.rows[#view.rows + 1] = {
			line = lineStop.line,
			name = hub.entityName(lineStop.line),
			weight = entry.weight or hub.DEFAULT_WEIGHT,
			targetShare = entry.targetShare,
			actualShare = entry.actualShare,
			maxLoad = entry.maxLoad,
			saturated = view.enabled and entry.saturated == true,
			fullLoad = lineStop.loadMode ~= api.type.Line.LoadMode.LOAD_IF_AVAILABLE,
		}
	end
	table.sort(view.rows, function(a, b) return a.name < b.name end)
	return view
end

local function cargoSelector(view, selected)
	if #view.cargoOptions < 2 then
		return text(_("Cargo") .. ": " .. hub.cargoName(view.cargo))
	end
	local items = {}
	for _, cargo in ipairs(view.cargoOptions) do
		items[#items + 1] = builtin.ComboBoxItem{ value = cargo, content = text(hub.cargoName(cargo)) }
	end
	return builtin.ComboBox{
		value = view.cargo,
		items = items,
		onValueChange = function(value) selected:set(value) end,
	}
end

local function lineRow(warehouse, view, row)
	local shown = view.enabled
	return builtin.Row{
		cells = {
			text(row.name),
			builtin.Slider{
				min = 0,
				max = 100,
				step = 1,
				pageStep = 10,
				horizontal = true,
				value = row.weight,
				onValueChange = function(value)
					hub.sendEvent(hub.EVENT_SET_WEIGHT, { warehouse = warehouse, cargo = view.cargo, line = row.line, weight = value })
				end,
			},
			text(shown and percent(row.targetShare) or "–"),
			text(shown and percent(row.actualShare) or "–"),
			text(shown and row.maxLoad and percent(row.maxLoad) or "–", row.saturated and "negative" or nil),
		},
	}
end

local function warnings(view)
	local result = {}
	if #view.rows == 0 then
		result[#result + 1] = content_card.makeInfoHint(_("No line stops at a station of this warehouse."), true)
	end
	if not view.enabled then
		return result
	end
	for _, row in ipairs(view.rows) do
		if row.saturated then
			result[#result + 1] = text(string.format(_("%s cannot carry its share; the surplus goes to the other lines."), row.name), "negative")
		end
		if row.fullLoad then
			result[#result + 1] = text(string.format(_("%s: set the hub stop to \"Load if Available\", otherwise throttled vehicles wait here."), row.name), "negative")
		end
	end
	if view.overflow then
		result[#result + 1] = text(_("All lines are at capacity and the stock is growing. Add vehicles."), "negative")
	end
	return result
end

local HubCardContent = react.RegisterRecipe("PartialLoadHubCardContent", function(params)
	local selected = react.useState(nil)
	local viewState = engine_react_util.useStepStateTimer(function()
		return makeView(params.warehouse, selected:old())
	end, 1.0)
	local view = viewState:old()

	if view.cargo == nil then
		return content_card.makeInfoHint(_("This warehouse holds no cargo yet."), true)
	end

	local headerRow = builtin.Row{
		cells = { text(_("Line")), text(_("Weight")), text(_("Target")), text(_("Actual")), text(_("Max load")) },
	}
	local rows = { headerRow }
	for _, row in ipairs(view.rows) do
		rows[#rows + 1] = lineRow(params.warehouse, view, row)
	end

	local fill = view.capacity > 0 and view.used / view.capacity or 0
	local stockLabel = string.format(_("%d / %d stored, %d of it %s"), view.used, view.capacity, view.stock, hub.cargoName(view.cargo))
	if view.inflow then
		stockLabel = stockLabel .. "  ·  " .. string.format(_("inflow %d / 30 days"), math.floor(view.inflow + 0.5))
	end

	local children = {
		cargoSelector(view, selected),
		builtin.CheckBox{
			label = _("Balance this cargo across the lines"),
			value = view.enabled and 1 or 0,
			onValueChange = function(value)
				hub.sendEvent(hub.EVENT_SET_ENABLED, { warehouse = params.warehouse, cargo = view.cargo, enabled = value == 1 })
			end,
		},
		builtin.ProgressBar{ value = math.min(1, fill), label = stockLabel },
		builtin.TableLayout{ columnWeights = { 3, 3, 1, 1, 1 }, rows = rows },
	}
	for _, warning in ipairs(warnings(view)) do
		children[#children + 1] = warning
	end

	return builtin.BoxLayout{
		orientation = builtin.type.Orientation.Vertical,
		children = children,
	}
end)

local HubCardPlugin = react.RegisterPluginRecipe(warehouse_eow.WarehouseEowExtensionPoint, "PartialLoadHubCardPlugin", function(params)
	return builtin.BoxLayout{
		child = content_card.ContentCard{
			title = _("Partial Load Balancing"),
			recipeAndParamPermanent = content_card.makeRecipeAndParam(HubCardContent, { warehouse = params.entityId }),
			hasPermanentFocusables = true,
			gameCtx = params.gameCtx,
			showOnRightSide = params.showCalloutOnRightSide,
		},
	}
end)

function data()
	return {
		HubCardPlugin = HubCardPlugin,
	}
end
