local MOD = "mzeiher_partial_load/content"
local CARGO = 5
local DAY = 1000
local STEP = 50
local STEPS_PER_DAY = DAY / STEP
local AT_TERMINAL, EN_ROUTE = 2, 1
local WAREHOUSE, CONSTRUCTION, STATION, HUB_GROUP, OTHER_GROUP, STOCK_LIST = 100, 101, 200, 300, 301, 500

local function deepcopy(value)
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for k, v in pairs(value) do
		copy[k] = deepcopy(v)
	end
	return copy
end

local function newWorld(spec)
	local world = { time = 0, stock = 0, stockCapacity = spec.stockCapacity, supplyPerDay = spec.supplyPerDay, lines = {}, vehicles = {}, picked = {}, lineUpdates = 0, lineUpdatesByLine = {}, removed = {}, lineVehicleCalls = 0, mixed = spec.mixed, otherCargo = spec.otherCargo or 0 }
	for _, lineSpec in ipairs(spec.lines) do
		world.lines[lineSpec.id] = {
			stops = {
				{ stationGroup = HUB_GROUP, loadMode = "LOAD_IF_AVAILABLE", stopConfig = { load = {}, maxLoad = {} } },
				{ stationGroup = OTHER_GROUP, loadMode = "LOAD_IF_AVAILABLE", stopConfig = { load = {}, maxLoad = {} } },
			},
			customFilters = false,
			vehicles = {},
		}
		world.picked[lineSpec.id] = {}
		for i = 1, lineSpec.vehicles do
			local id = lineSpec.id * 100 + i
			world.vehicles[id] = {
				line = lineSpec.id, capacity = lineSpec.capacity, travel = lineSpec.travel,
				phase = "toHub", timer = i * 3, cargo = 0, stopIndex = 0, arrivesWith = lineSpec.arrivesWith or 0,
			}
			table.insert(world.lines[lineSpec.id].vehicles, id)
		end
	end
	return world
end

local function maxLoadOf(world, lineId)
	return world.lines[lineId].stops[1].stopConfig.maxLoad[CARGO + 1] or 1
end

local function stepVehicles(world)
	local day = math.floor(world.time / DAY)
	for id, v in pairs(world.vehicles) do
		v.timer = v.timer - 1
		if v.phase == "hub" then
			if v.timer <= 2 then
				local allowed = math.floor(v.capacity * maxLoadOf(world, v.line) + 1e-9) - v.cargo
				local take = math.max(0, math.min(allowed, world.stock))
				v.cargo = v.cargo + take
				world.stock = world.stock - take
				world.picked[v.line][day] = (world.picked[v.line][day] or 0) + take
			end
			if v.timer <= 0 then
				v.phase, v.timer, v.stopIndex = "toDest", v.travel, 1
			end
		elseif v.phase == "toDest" and v.timer <= 0 then
			v.phase, v.timer, v.cargo = "dest", 2, v.arrivesWith
		elseif v.phase == "dest" and v.timer <= 0 then
			v.phase, v.timer, v.stopIndex = "toHub", v.travel, 0
		elseif v.phase == "toHub" and v.timer <= 0 then
			v.phase, v.timer = "hub", 4
		end
	end
end

local function installApi(world)
	local types = {
		GAME_TIME = "GAME_TIME", WAREHOUSE = "WAREHOUSE", CONSTRUCTION = "CONSTRUCTION", STOCK_LIST = "STOCK_LIST",
		LINE = "LINE", TRANSPORT_VEHICLE = "TRANSPORT_VEHICLE", NAME = "NAME", GAME_SCRIPT = "GAME_SCRIPT",
	}
	local cargoNames = {}
	for id = 0, 9 do
		cargoNames[id] = "CARGO_" .. id
	end

	local function component(entity, kind)
		if kind == types.GAME_TIME then
			return { gameTime = world.time }
		elseif kind == types.WAREHOUSE and entity == WAREHOUSE then
			return { stockList = STOCK_LIST, construction = CONSTRUCTION }
		elseif kind == types.CONSTRUCTION and entity == CONSTRUCTION then
			return { stations = { STATION } }
		elseif kind == types.STOCK_LIST and entity == STOCK_LIST then
			return { stocks = { { cargoType = world.mixed and -1 or CARGO, cargoTypes = {}, capacity = world.stockCapacity } } }
		elseif kind == types.LINE and world.lines[entity] then
			local line = world.lines[entity]
			return deepcopy({ stops = line.stops, customFilters = line.customFilters })
		elseif kind == types.TRANSPORT_VEHICLE and world.vehicles[entity] then
			local v = world.vehicles[entity]
			local caps = {}
			for i = 1, 10 do
				caps[i] = 0
			end
			caps[CARGO + 1] = v.capacity
			return { stopIndex = v.stopIndex, config = { allCaps = caps } }
		elseif kind == types.NAME then
			return { name = "Entity " .. entity }
		end
		return nil
	end

	_G.api = {
		util = { getDefaultDayDuration = function() return DAY end },
		type = {
			ComponentType = types,
			enum = { TransportVehicleState = { AT_TERMINAL = AT_TERMINAL, EN_ROUTE = EN_ROUTE } },
			Line = {
				new = function(comp) return deepcopy(comp) end,
				StopConfig = { new = function(cfg) return deepcopy(cfg) end },
				LoadMode = { LOAD_IF_AVAILABLE = "LOAD_IF_AVAILABLE" },
			},
		},
		res = {
			cargoTypeRep = {
				getAll = function() return cargoNames end,
				hasCargoType = function(_, cargo) return world.mixed and cargo == CARGO end,
			},
		},
		engine = {
			getComponent = component,
			entityExists = function(entity) return not world.removed[entity] end,
			util = { getWorld = function() return 0 end },
			system = {
				simEntityAtStockSystem = {
					getStockCountForCargoType = function(stockList, stockId, cargo)
						assert(stockList == STOCK_LIST and stockId == 0 and cargo == CARGO)
						return world.stock
					end,
					getStockCount = function(stockList, stockId)
						assert(stockList == STOCK_LIST and stockId == 0)
						return world.stock + world.otherCargo
					end,
				},
				stationGroupSystem = { getStationGroup = function(station) return station == STATION and HUB_GROUP or -1 end },
				lineSystem = {
					getLinesForStationGroup = function(group)
						local result = {}
						if group == HUB_GROUP then
							for id in pairs(world.lines) do
								result[#result + 1] = id
							end
							table.sort(result)
						end
						return result
					end,
				},
				transportVehicleSystem = {
					getLineVehicles = function(line)
						world.lineVehicleCalls = world.lineVehicleCalls + 1
						return world.lines[line].vehicles
					end,
					getVehiclesWithState = function(state)
						assert(state == AT_TERMINAL)
						local result = {}
						for id, v in pairs(world.vehicles) do
							if v.phase == "hub" or v.phase == "dest" then
								result[#result + 1] = id
							end
						end
						return result
					end,
				},
				simEntityAtVehicleSystem = {
					getVehicleSimEntitiesCountForCargoType = function(vehicle, cargo)
						assert(not world.removed[vehicle], "queried a removed vehicle")
						return cargo == CARGO and world.vehicles[vehicle].cargo or 0
					end,
				},
			},
		},
		cmd = {
			makeLineUpdateCmd = function(entity, data) return { kind = "LineUpdate", entity = entity, data = data } end,
			makeScriptingSendEventCmd = function(src, id, name, param) return { kind = "Event", src = src, id = id, name = name, param = param } end,
			sendCommand = function(cmd)
				if cmd.kind == "LineUpdate" then
					world.lines[cmd.entity].stops = deepcopy(cmd.data.stops)
					world.lines[cmd.entity].customFilters = cmd.data.customFilters
					world.lineUpdates = world.lineUpdates + 1
					world.lineUpdatesByLine[cmd.entity] = (world.lineUpdatesByLine[cmd.entity] or 0) + 1
				end
			end,
		},
	}

	_G.ug_require = function(path)
		return dofile(MOD .. path)
	end
end

local function loadScript()
	_G.data = nil
	dofile(MOD .. "/partial_load/partial_load.script.lua")
	return _G.data()
end

local function newState()
	local stored, subscriptions = nil, {}
	return {
		get = function() return deepcopy(stored) end,
		set = function(_, value) stored = deepcopy(value) end,
		hasEventSubscriptions = function() return next(subscriptions) ~= nil end,
		subscribeToEvent = function(_, name) subscriptions[name] = true end,
		raw = function() return stored end,
		restore = function(value) stored = deepcopy(value) end,
	}
end

local function sharesOverLastDays(world, lineIds, days)
	local lastDay = math.floor(world.time / DAY) - 1
	local totals, sum = {}, 0
	for _, id in ipairs(lineIds) do
		totals[id] = 0
		for day = lastDay - days + 1, lastDay do
			totals[id] = totals[id] + (world.picked[id][day] or 0)
		end
		sum = sum + totals[id]
	end
	for _, id in ipairs(lineIds) do
		totals[id] = sum > 0 and totals[id] / sum or 0
	end
	return totals, sum
end

local function run(spec)
	local world = newWorld(spec)
	installApi(world)
	local hub = dofile(MOD .. "/partial_load/hub.lua")
	local script = loadScript()
	local state = newState()
	script.update({}, state, STEP)

	if spec.enable then
		for _, lineSpec in ipairs(spec.lines) do
			script.handleEvent({}, state, hub.EVENT_ID, hub.EVENT_ID, hub.EVENT_SET_WEIGHT,
				{ warehouse = WAREHOUSE, cargo = CARGO, line = lineSpec.id, weight = lineSpec.weight })
		end
		script.handleEvent({}, state, hub.EVENT_ID, hub.EVENT_ID, hub.EVENT_SET_ENABLED,
			{ warehouse = WAREHOUSE, cargo = CARGO, enabled = true })
	end

	local supplyAccumulator = 0
	for _ = 1, spec.days * STEPS_PER_DAY do
		world.time = world.time + STEP
		supplyAccumulator = supplyAccumulator + spec.supplyPerDay / STEPS_PER_DAY
		local add = math.floor(supplyAccumulator)
		supplyAccumulator = supplyAccumulator - add
		world.stock = math.min(world.stockCapacity, world.stock + add)
		stepVehicles(world)
		script.update({}, state, STEP)
	end
	return world, state, script, hub
end

local failures, passed = 0, 0
local function test(name, fn)
	local ok, err = pcall(fn)
	if ok then
		passed = passed + 1
	else
		failures = failures + 1
		print("FAIL " .. name .. ": " .. tostring(err))
	end
end

local function within(actual, expected, tolerance, label)
	if math.abs(actual - expected) > tolerance then
		error(string.format("%s: expected %.3f ± %.3f, got %.3f", label, expected, tolerance, actual), 2)
	end
end

local LINES = {
	{ id = 1, weight = 20, vehicles = 2, capacity = 20, travel = 10 },
	{ id = 2, weight = 50, vehicles = 1, capacity = 200, travel = 60 },
	{ id = 3, weight = 30, vehicles = 2, capacity = 50, travel = 30 },
}

test("without balancing the split is far from 20/50/30", function()
	local world = run({ lines = LINES, supplyPerDay = 20, stockCapacity = 1000, days = 150, enable = false })
	local shares = sharesOverLastDays(world, { 1, 2, 3 }, 30)
	local deviation = math.abs(shares[1] - 0.2) + math.abs(shares[2] - 0.5) + math.abs(shares[3] - 0.3)
	assert(deviation > 0.2, string.format("baseline already balanced: %.2f/%.2f/%.2f", shares[1], shares[2], shares[3]))
	assert(world.lineUpdates == 0, "no line updates while disabled")
end)

test("balancing converges to 20/50/30", function()
	local world, state = run({ lines = LINES, supplyPerDay = 20, stockCapacity = 1000, days = 480, enable = true })
	local shares, total = sharesOverLastDays(world, { 1, 2, 3 }, 90)
	assert(total > 0.9 * 20 * 90, "lines carried the supply, got " .. total)
	within(shares[1], 0.2, 0.03, "line 1")
	within(shares[2], 0.5, 0.03, "line 2")
	within(shares[3], 0.3, 0.03, "line 3")
	local group = state.raw().groups[WAREHOUSE .. ":" .. CARGO]
	assert(group.lines["1"].maxLoad < 1 and group.lines["3"].maxLoad < 1, "short lines are throttled")
	assert(world.lines[1].customFilters, "custom filters set on the line")
end)

test("a line without enough capacity passes its surplus on", function()
	local lines = deepcopy(LINES)
	lines[2].capacity = 40
	local world, state = run({ lines = lines, supplyPerDay = 20, stockCapacity = 1000, days = 480, enable = true })
	local shares = sharesOverLastDays(world, { 1, 2, 3 }, 90)
	local group = state.raw().groups[WAREHOUSE .. ":" .. CARGO]
	assert(group.lines["2"].saturated, "line 2 saturated")
	within(group.lines["2"].maxLoad, 1, 1e-9, "line 2 maxLoad")
	local lineTwoShare = 40 * STEPS_PER_DAY / (2 * 60 + 4 + 2) / 20
	within(shares[2], lineTwoShare, 0.03, "line 2 carries its capacity")
	within(shares[1], (1 - lineTwoShare) * 0.4, 0.03, "line 1 gets 20/50 of the surplus split")
	within(shares[3], (1 - lineTwoShare) * 0.6, 0.03, "line 3 gets 30/50 of the surplus split")
end)

test("cargo already on board at the hub does not count as a pickup", function()
	local lines = deepcopy(LINES)
	lines[3].arrivesWith = 10
	local world, state = run({ lines = lines, supplyPerDay = 20, stockCapacity = 1000000, days = 480, enable = true })
	assert(world.stock < 0.7 * 1000000, "no stock pressure involved")
	local correction = state.raw().groups[WAREHOUSE .. ":" .. CARGO].lines["3"].correction or 1
	assert(correction > 0.8 and correction < 1.25, "on-board cargo handled by the formula, not the correction: " .. correction)
	local shares = sharesOverLastDays(world, { 1, 2, 3 }, 90)
	within(shares[1], 0.2, 0.03, "line 1")
	within(shares[2], 0.5, 0.03, "line 2")
	within(shares[3], 0.3, 0.03, "line 3")
end)

test("disabling restores full load on every hub stop", function()
	local world, state, script, hub = run({ lines = LINES, supplyPerDay = 20, stockCapacity = 1000, days = 60, enable = true })
	assert(maxLoadOf(world, 1) < 1, "line 1 throttled before")
	script.handleEvent({}, state, hub.EVENT_ID, hub.EVENT_ID, hub.EVENT_SET_ENABLED,
		{ warehouse = WAREHOUSE, cargo = CARGO, enabled = false })
	for id = 1, 3 do
		within(maxLoadOf(world, id), 1, 1e-9, "line " .. id)
		assert(world.lines[id].customFilters == false, "automatic filters handed back to line " .. id)
	end
end)

test("disabling releases the hub stop after the line's stops changed", function()
	local world, state, script, hub = run({ lines = LINES, supplyPerDay = 20, stockCapacity = 1000, days = 60, enable = true })
	assert(maxLoadOf(world, 1) < 1, "line 1 throttled before")
	table.insert(world.lines[1].stops, 1, { stationGroup = 302, loadMode = "LOAD_IF_AVAILABLE", stopConfig = { load = {}, maxLoad = {} } })
	script.handleEvent({}, state, hub.EVENT_ID, hub.EVENT_ID, hub.EVENT_SET_ENABLED,
		{ warehouse = WAREHOUSE, cargo = CARGO, enabled = false })
	within(world.lines[1].stops[2].stopConfig.maxLoad[CARGO + 1], 1, 1e-9, "hub stop released")
	within(world.lines[1].stops[1].stopConfig.maxLoad[CARGO + 1], 1, 1e-9, "new stop untouched")
end)

test("custom filters leave every stop with complete load settings", function()
	local world = run({ lines = LINES, supplyPerDay = 20, stockCapacity = 1000, days = 10, enable = true })
	for _, stop in ipairs(world.lines[2].stops) do
		assert(#stop.stopConfig.load == 10 and #stop.stopConfig.maxLoad == 10, "complete arrays")
		assert(stop.stopConfig.load[CARGO + 1] == true, "cargo still loaded")
	end
	within(world.lines[2].stops[2].stopConfig.maxLoad[CARGO + 1], 1, 1e-9, "other stop unthrottled")
end)

test("dragging a weight slider does not add ticks", function()
	local world, state, script, hub = run({ lines = LINES, supplyPerDay = 20, stockCapacity = 1000, days = 30, enable = true })
	local callsBefore = world.lineVehicleCalls
	local steps = 40
	for i = 1, steps do
		script.handleEvent({}, state, hub.EVENT_ID, hub.EVENT_ID, hub.EVENT_SET_WEIGHT,
			{ warehouse = WAREHOUSE, cargo = CARGO, line = 1, weight = 20 + i })
		world.time = world.time + STEP
		stepVehicles(world)
		script.update({}, state, STEP)
	end
	local ticks = (world.lineVehicleCalls - callsBefore) / #LINES
	assert(ticks <= steps * STEP / (DAY / 4) + 1, "ticks during drag: " .. ticks)
	assert(state.raw().groups[WAREHOUSE .. ":" .. CARGO].lines["1"].weight == 20 + steps, "last weight kept")
end)

test("re-enabling does not record a stale hub visit", function()
	local world, state, script, hub = run({ lines = LINES, supplyPerDay = 20, stockCapacity = 1000, days = 30, enable = true })
	local train = world.vehicles[201]
	local function step()
		world.time = world.time + STEP
		stepVehicles(world)
		script.update({}, state, STEP)
	end
	local function setEnabled(enabled)
		script.handleEvent({}, state, hub.EVENT_ID, hub.EVENT_ID, hub.EVENT_SET_ENABLED,
			{ warehouse = WAREHOUSE, cargo = CARGO, enabled = enabled })
	end
	while train.phase ~= "hub" do
		step()
	end
	step()
	setEnabled(false)
	while train.phase ~= "toDest" do
		step()
	end
	for _ = 1, 20 do
		step()
	end
	local balancer = dofile(MOD .. "/partial_load/balancer.lua")
	local before = balancer.sum(state.raw().groups[WAREHOUSE .. ":" .. CARGO].lines["2"].picked)
	setEnabled(true)
	for _ = 1, 20 do
		step()
	end
	assert(train.phase == "toDest", "train still travelling")
	local after = balancer.sum(state.raw().groups[WAREHOUSE .. ":" .. CARGO].lines["2"].picked)
	assert(after == before, string.format("phantom pickup: %d -> %d", before, after))
end)

local function stepper(world, script, state)
	return function(n)
		for _ = 1, n or 1 do
			world.time = world.time + STEP
			stepVehicles(world)
			script.update({}, state, STEP)
		end
	end
end

test("a line that cannot carry the cargo is never touched", function()
	local lines = deepcopy(LINES)
	lines[4] = { id = 4, weight = 10, vehicles = 1, capacity = 0, travel = 20 }
	local world = run({ lines = lines, supplyPerDay = 20, stockCapacity = 1000, days = 60, enable = true })
	assert(world.lineUpdatesByLine[4] == nil, "line 4 updated")
	assert(world.lines[4].customFilters == false, "line 4 filters untouched")
end)

test("a manual max load on a balanced hub stop is overwritten", function()
	local world, state, script = run({ lines = LINES, supplyPerDay = 20, stockCapacity = 1000, days = 200, enable = true })
	world.lines[1].stops[1].stopConfig.maxLoad[CARGO + 1] = 0.9
	stepper(world, script, state)(STEPS_PER_DAY)
	local wanted = state.raw().groups[WAREHOUSE .. ":" .. CARGO].lines["1"].maxLoad
	assert(wanted < 0.8, "computed value is far from the manual one")
	within(maxLoadOf(world, 1), wanted, 0.05, "manual edit replaced")
end)

test("an earlier hub stop takes over and the old one is released", function()
	local world, state, script = run({ lines = LINES, supplyPerDay = 20, stockCapacity = 1000, days = 60, enable = true })
	assert(maxLoadOf(world, 1) < 1, "line 1 throttled before")
	table.insert(world.lines[1].stops, 1, { stationGroup = HUB_GROUP, loadMode = "LOAD_IF_AVAILABLE", stopConfig = { load = {}, maxLoad = {} } })
	stepper(world, script, state)(STEPS_PER_DAY)
	within(world.lines[1].stops[2].stopConfig.maxLoad[CARGO + 1], 1, 1e-9, "old hub stop released")
	assert(world.lines[1].stops[1].stopConfig.maxLoad[CARGO + 1] < 1, "new first hub stop throttled")
end)

test("a vehicle removed at the hub is ignored", function()
	local world, state, script = run({ lines = LINES, supplyPerDay = 20, stockCapacity = 1000, days = 30, enable = true })
	local step = stepper(world, script, state)
	local train = world.vehicles[201]
	while train.phase ~= "hub" do
		step()
	end
	step()
	world.removed[201] = true
	train.phase = "gone"
	step(STEPS_PER_DAY)
end)

test("loading an earlier save drops in-memory vehicle snapshots", function()
	local world, state, script = run({ lines = LINES, supplyPerDay = 20, stockCapacity = 1000, days = 30, enable = true })
	local step = stepper(world, script, state)
	local train = world.vehicles[201]
	while train.phase ~= "toDest" do
		step()
	end
	local savedTime, savedState = world.time, deepcopy(state.raw())
	while train.phase ~= "hub" do
		step()
	end
	step()

	world.time = savedTime
	train.phase, train.timer, train.cargo, train.stopIndex = "toDest", 1000, 77, 1
	state.restore(savedState)
	local balancer = dofile(MOD .. "/partial_load/balancer.lua")
	local before = balancer.sum(savedState.groups[WAREHOUSE .. ":" .. CARGO].lines["2"].picked)
	local calls = world.lineVehicleCalls
	step(2)
	assert(world.lineVehicleCalls > calls, "ticking resumed after going back in time")
	local after = balancer.sum(state.raw().groups[WAREHOUSE .. ":" .. CARGO].lines["2"].picked)
	assert(after == before, string.format("phantom pickup: %d -> %d", before, after))
end)

test("other cargo filling a shared stock opens every line", function()
	local world = run({ lines = LINES, supplyPerDay = 20, stockCapacity = 1000, days = 100, enable = true, mixed = true, otherCargo = 960 })
	for id = 1, 3 do
		within(maxLoadOf(world, id), 1, 1e-9, "line " .. id)
	end
end)

test("a filling warehouse opens every line", function()
	local world = run({ lines = LINES, supplyPerDay = 120, stockCapacity = 1000, days = 100, enable = true })
	for id = 1, 3 do
		within(maxLoadOf(world, id), 1, 1e-9, "line " .. id)
	end
end)

print(string.format("%d passed, %d failed", passed, failures))
os.exit(failures == 0 and 0 or 1)
