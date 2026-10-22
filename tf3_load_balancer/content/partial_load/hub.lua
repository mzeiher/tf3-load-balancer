local hub = {}

hub.SCRIPT_NAME = "mzeiher_partial_load::/partial_load/partial_load.gs"
hub.EVENT_ID = "mzeiher_partial_load"
hub.EVENT_SET_ENABLED = "PartialLoad.SetEnabled"
hub.EVENT_SET_WEIGHT = "PartialLoad.SetWeight"
hub.DEFAULT_WEIGHT = 10

function hub.groupKey(warehouse, cargo)
	return tostring(warehouse) .. ":" .. tostring(cargo)
end

function hub.percent(value)
	return string.format("%d%%", math.floor((value or 0) * 100 + 0.5))
end

local function stockListOf(warehouse)
	local component = api.engine.getComponent(warehouse, api.type.ComponentType.WAREHOUSE)
	local entity = component and component.stockList
	return entity, entity and api.engine.getComponent(entity, api.type.ComponentType.STOCK_LIST)
end

local function acceptsCargo(stock, cargo)
	if stock.cargoType == cargo then
		return true
	end
	return stock.cargoType < 0 and api.res.cargoTypeRep.hasCargoType(stock.cargoTypes, cargo)
end

-- used counts every cargo in the matching stocks, because a mixed stock's capacity is shared.
function hub.stockUsedAndCapacity(warehouse, cargo)
	local stockListEntity, stockList = stockListOf(warehouse)
	if not stockList then
		return 0, 0, 0
	end
	local stocks = api.engine.system.simEntityAtStockSystem
	local stock, used, capacity = 0, 0, 0
	for i, entry in ipairs(stockList.stocks) do
		if acceptsCargo(entry, cargo) then
			stock = stock + stocks.getStockCountForCargoType(stockListEntity, i - 1, cargo)
			used = used + stocks.getStockCount(stockListEntity, i - 1)
			capacity = capacity + entry.capacity
		end
	end
	return stock, used, capacity
end

function hub.cargoTypesInStock(warehouse)
	local stockListEntity, stockList = stockListOf(warehouse)
	local result = {}
	if not stockList then
		return result
	end
	for cargo in pairs(api.res.cargoTypeRep.getAll()) do
		for i, entry in ipairs(stockList.stocks) do
			if acceptsCargo(entry, cargo)
				and api.engine.system.simEntityAtStockSystem.getStockCountForCargoType(stockListEntity, i - 1, cargo) > 0 then
				result[#result + 1] = cargo
				break
			end
		end
	end
	table.sort(result)
	return result
end

local function hubStationGroups(warehouse)
	local groups = {}
	local component = api.engine.getComponent(warehouse, api.type.ComponentType.WAREHOUSE)
	local construction = component and api.engine.getComponent(component.construction, api.type.ComponentType.CONSTRUCTION)
	if not construction then
		return groups
	end
	for _, station in ipairs(construction.stations) do
		local group = api.engine.system.stationGroupSystem.getStationGroup(station)
		if group and group >= 0 then
			groups[group] = true
		end
	end
	return groups
end

-- Stop indices are zero-based, like TransportVehicle.stopIndex and the line window's stopIndex.
function hub.lineStops(warehouse)
	local groups = hubStationGroups(warehouse)
	local lineEntities, seenLines = {}, {}
	for group in pairs(groups) do
		for _, lineEntity in ipairs(api.engine.system.lineSystem.getLinesForStationGroup(group)) do
			if not seenLines[lineEntity] then
				seenLines[lineEntity] = true
				lineEntities[#lineEntities + 1] = lineEntity
			end
		end
	end
	table.sort(lineEntities)

	local result = {}
	for _, lineEntity in ipairs(lineEntities) do
		local line = api.engine.getComponent(lineEntity, api.type.ComponentType.LINE)
		local entry
		for index, stop in ipairs(line and line.stops or {}) do
			if groups[stop.stationGroup] then
				if entry == nil then
					entry = { line = lineEntity, stop = index - 1, loadMode = stop.loadMode, hubStops = {} }
					result[#result + 1] = entry
				end
				table.insert(entry.hubStops, index - 1)
			end
		end
	end
	return result
end

function hub.entityName(entity)
	local component = api.engine.getComponent(entity, api.type.ComponentType.NAME)
	return component and component.name or tostring(entity)
end

function hub.warehouseName(warehouse)
	local component = api.engine.getComponent(warehouse, api.type.ComponentType.NAME)
	if component then
		return component.name
	end
	local warehouseComponent = api.engine.getComponent(warehouse, api.type.ComponentType.WAREHOUSE)
	return hub.entityName(warehouseComponent and warehouseComponent.construction or warehouse)
end

function hub.cargoName(cargo)
	local cargoType = api.res.cargoTypeRep.get(cargo)
	return cargoType and _(cargoType.name) or tostring(cargo)
end

function hub.readState()
	local entity = api.engine.system.gameScriptSystem.getEntityForGameScript(hub.SCRIPT_NAME)
	local component = entity and api.engine.getComponent(entity, api.type.ComponentType.GAME_SCRIPT)
	return component and component.state or {}
end

function hub.sendEvent(name, param)
	api.cmd.sendCommand(api.cmd.makeScriptingSendEventCmd(hub.EVENT_ID, hub.EVENT_ID, name, param))
end

return hub
