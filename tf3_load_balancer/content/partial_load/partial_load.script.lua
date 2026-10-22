local balancer = ug_require "/partial_load/balancer.lua"
local hub = ug_require "/partial_load/hub.lua"

local STATE_VERSION = 1

local vehicleIndex = {}
local atHub = {}
local atOtherStop = {}
local nextTickTime = nil
local lastSeenTime = nil
local cargoTypeCount = nil

local function dayLength()
	return api.util.getDefaultDayDuration()
end

local function gameTime()
	return api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME).gameTime
end

local function initState(state)
	if state == nil or state.version == nil then
		return { version = STATE_VERSION, groups = {} }
	end
	return state
end

local function newLine(lineEntity)
	return {
		line = lineEntity,
		weight = hub.DEFAULT_WEIGHT,
		picked = balancer.newWindow(),
		offered = balancer.newWindow(),
		carried = balancer.newWindow(),
	}
end

local function ensureGroup(s, warehouse, cargo)
	local key = hub.groupKey(warehouse, cargo)
	if not s.groups[key] then
		s.groups[key] = {
			warehouse = warehouse,
			cargo = cargo,
			enabled = false,
			inflow = balancer.newWindow(),
			pickedSinceTick = 0,
			lines = {},
		}
	end
	return s.groups[key]
end

local function countCargoTypes()
	if cargoTypeCount == nil then
		cargoTypeCount = 0
		for id in pairs(api.res.cargoTypeRep.getAll()) do
			cargoTypeCount = math.max(cargoTypeCount, id + 1)
		end
	end
	return cargoTypeCount
end

-- Once customFilters is on the game stops filling stop configs, so every stop needs complete arrays.
local function completeStopConfig(stopConfig)
	local config = api.type.Line.StopConfig.new(stopConfig)
	local load, maxLoad = {}, {}
	for i = 1, math.max(countCargoTypes(), #config.load, #config.maxLoad) do
		load[i] = config.load[i] ~= false
		maxLoad[i] = config.maxLoad[i] or 1
	end
	config.load = load
	config.maxLoad = maxLoad
	return config
end

-- Compares against the line's actual values, so a write lost to another update or a manual edit is redone.
local function writeHubStops(entry, cargo, value, restoreAutomatic)
	local component = api.engine.getComponent(entry.line, api.type.ComponentType.LINE)
	if not component then
		return
	end
	local wanted = {}
	for _, index in ipairs(entry.hubStops) do
		wanted[index] = 1
	end
	wanted[entry.stop] = value

	local changed = restoreAutomatic and component.customFilters
	for index, want in pairs(wanted) do
		local stop = component.stops[index + 1]
		if stop and balancer.needsUpdate(stop.stopConfig.maxLoad[cargo + 1] or 1, want) then
			changed = true
		end
	end
	if not changed then
		return
	end

	local lineData = api.type.Line.new(component)
	local stops = {}
	for i, stop in ipairs(lineData.stops) do
		stop.stopConfig = completeStopConfig(stop.stopConfig)
		if wanted[i - 1] then
			stop.stopConfig.maxLoad[cargo + 1] = wanted[i - 1]
		end
		stops[i] = stop
	end
	lineData.stops = stops
	if restoreAutomatic then
		lineData.customFilters = false
	elseif not component.customFilters then
		lineData.customFilters = true
		entry.flippedFilters = true
	end
	api.cmd.sendCommand(api.cmd.makeLineUpdateCmd(entry.line, lineData))
end

local function syncLines(group)
	local present = {}
	for _, lineStop in ipairs(hub.lineStops(group.warehouse)) do
		local key = tostring(lineStop.line)
		present[key] = true
		local entry = group.lines[key]
		if entry == nil then
			entry = newLine(lineStop.line)
			group.lines[key] = entry
		end
		entry.stop = lineStop.stop
		entry.hubStops = lineStop.hubStops
	end
	for key in pairs(group.lines) do
		if not present[key] then
			group.lines[key] = nil
		end
	end
end

local function releaseGroup(group)
	syncLines(group)
	for _, entry in pairs(group.lines) do
		writeHubStops(entry, group.cargo, 1, entry.flippedFilters)
		entry.flippedFilters = nil
		entry.maxLoad = nil
	end
end

local function rebuildVehicleIndex(s)
	vehicleIndex = {}
	for groupKey, group in pairs(s.groups) do
		if group.enabled then
			for lineKey, entry in pairs(group.lines) do
				for _, vehicle in ipairs(api.engine.system.transportVehicleSystem.getLineVehicles(entry.line)) do
					vehicleIndex[vehicle] = vehicleIndex[vehicle] or {}
					table.insert(vehicleIndex[vehicle], { group = groupKey, line = lineKey })
				end
			end
		end
	end
	for vehicle in pairs(atHub) do
		if not vehicleIndex[vehicle] then
			atHub[vehicle] = nil
		end
	end
	for vehicle in pairs(atOtherStop) do
		if not vehicleIndex[vehicle] then
			atOtherStop[vehicle] = nil
		end
	end
end

local function recordDeparture(s, vehicle, snapshots, day)
	if not api.engine.entityExists(vehicle) then
		return
	end
	local transportVehicle = api.engine.getComponent(vehicle, api.type.ComponentType.TRANSPORT_VEHICLE)
	for _, snapshot in ipairs(snapshots) do
		local group = s.groups[snapshot.group]
		local entry = group and group.lines[snapshot.line]
		if entry then
			local now = api.engine.system.simEntityAtVehicleSystem.getVehicleSimEntitiesCountForCargoType(vehicle, group.cargo)
			local loaded = math.max(0, now - snapshot.count)
			local capacity = transportVehicle and transportVehicle.config.allCaps[group.cargo + 1] or 0
			local carried = math.min(snapshot.count, capacity)
			balancer.add(entry.picked, day, loaded)
			balancer.add(entry.offered, day, capacity - carried)
			balancer.add(entry.carried, day, carried)
			group.pickedSinceTick = group.pickedSinceTick + loaded
		end
	end
end

local function trackVehicles(s, day)
	local atTerminal = {}
	for _, vehicle in ipairs(api.engine.system.transportVehicleSystem.getVehiclesWithState(api.type.enum.TransportVehicleState.AT_TERMINAL)) do
		atTerminal[vehicle] = true
	end

	local departed = false
	for vehicle, memberships in pairs(vehicleIndex) do
		if atTerminal[vehicle] then
			if not atHub[vehicle] and not atOtherStop[vehicle] then
				local transportVehicle = api.engine.getComponent(vehicle, api.type.ComponentType.TRANSPORT_VEHICLE)
				local snapshots = {}
				for _, membership in ipairs(memberships) do
					local group = s.groups[membership.group]
					local entry = group and group.lines[membership.line]
					if entry and transportVehicle and transportVehicle.stopIndex == entry.stop then
						snapshots[#snapshots + 1] = {
							group = membership.group,
							line = membership.line,
							count = api.engine.system.simEntityAtVehicleSystem.getVehicleSimEntitiesCountForCargoType(vehicle, group.cargo),
						}
					end
				end
				if #snapshots > 0 then
					atHub[vehicle] = snapshots
				else
					atOtherStop[vehicle] = true
				end
			end
		else
			atOtherStop[vehicle] = nil
			if atHub[vehicle] then
				recordDeparture(s, vehicle, atHub[vehicle], day)
				atHub[vehicle] = nil
				departed = true
			end
		end
	end
	return departed
end

local function balanceGroup(group, day)
	local stock, used, capacity = hub.stockUsedAndCapacity(group.warehouse, group.cargo)
	balancer.add(group.inflow, day, stock - (group.lastStock or stock) + group.pickedSinceTick)
	group.lastStock = stock
	group.pickedSinceTick = 0

	local lines, pickedTotal = {}, 0
	for key, entry in pairs(group.lines) do
		balancer.advance(entry.picked, day)
		balancer.advance(entry.offered, day)
		balancer.advance(entry.carried, day)
		local picked = balancer.sum(entry.picked)
		pickedTotal = pickedTotal + picked
		lines[#lines + 1] = {
			key = key,
			weight = entry.weight,
			capacity = balancer.sum(entry.offered),
			carried = balancer.sum(entry.carried),
			picked = picked,
			correction = entry.correction,
		}
	end

	local inflow = math.max(0, balancer.sum(group.inflow))
	local fill = capacity > 0 and used / capacity or nil
	local result, overflow = balancer.compute({ inflow = inflow, fill = fill, lines = lines })

	for _, line in ipairs(lines) do
		local entry = group.lines[line.key]
		local computed = result[line.key]
		writeHubStops(entry, group.cargo, computed.maxLoad, false)
		entry.maxLoad = computed.maxLoad
		entry.correction = computed.correction
		entry.targetShare = inflow > 0 and computed.target / inflow or 0
		entry.actualShare = pickedTotal > 0 and line.picked / pickedTotal or 0
		entry.saturated = computed.saturated
	end

	group.inflowWindow = inflow
	group.overflow = overflow
end

local function tick(s, day)
	for key, group in pairs(s.groups) do
		if not api.engine.entityExists(group.warehouse) then
			s.groups[key] = nil
		else
			syncLines(group)
			if group.enabled then
				balanceGroup(group, day)
			end
		end
	end
	rebuildVehicleIndex(s)
end

local function update(_userParams, state, _dt)
	if not state:hasEventSubscriptions() then
		state:subscribeToEvent(hub.EVENT_SET_ENABLED)
		state:subscribeToEvent(hub.EVENT_SET_WEIGHT)
	end

	local now = gameTime()
	local interval = dayLength() / 4
	if lastSeenTime ~= nil and (now < lastSeenTime or now - lastSeenTime > 10 * dayLength()) then
		vehicleIndex, atHub, atOtherStop, nextTickTime = {}, {}, {}, nil
	end
	lastSeenTime = now

	local tickDue = nextTickTime == nil or now >= nextTickTime
	if not tickDue and next(vehicleIndex) == nil then
		return
	end

	local s = initState(state:get())
	local day = math.floor(now / dayLength())
	local changed = false
	if tickDue then
		tick(s, day)
		nextTickTime = now + interval
		changed = true
	end
	if trackVehicles(s, day) then
		changed = true
	end

	if changed then
		state:set(s)
	end
end

local function handleEvent(_userParams, state, _src, id, name, param)
	if id ~= hub.EVENT_ID then
		return
	end
	local s = initState(state:get())

	if name == hub.EVENT_SET_ENABLED then
		local group = ensureGroup(s, param.warehouse, param.cargo)
		if group.enabled and not param.enabled then
			releaseGroup(group)
		end
		if param.enabled and not group.enabled then
			syncLines(group)
			group.lastStock = nil
			group.pickedSinceTick = 0
		end
		group.enabled = param.enabled
	elseif name == hub.EVENT_SET_WEIGHT then
		local group = ensureGroup(s, param.warehouse, param.cargo)
		syncLines(group)
		local entry = group.lines[tostring(param.line)]
		if entry then
			entry.weight = math.max(0, param.weight)
		end
	end

	state:set(s)
end

function data()
	return {
		update = update,
		handleEvent = handleEvent,
	}
end
