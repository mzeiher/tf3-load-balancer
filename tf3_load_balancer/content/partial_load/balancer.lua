local balancer = {}

balancer.WINDOW_DAYS = 30
balancer.PRESSURE_START = 0.7
balancer.PRESSURE_FULL = 0.95
balancer.MIN_CHANGE = 0.05
balancer.MIN_FEEDBACK_SAMPLE = 20
balancer.CORRECTION_GAIN = 0.005
balancer.CORRECTION_MIN = 0.5
balancer.CORRECTION_MAX = 2

local function clamp(value, low, high)
	return math.max(low, math.min(high, value))
end

function balancer.newWindow()
	return { values = {} }
end

function balancer.advance(window, day)
	local n = balancer.WINDOW_DAYS
	if window.lastDay == nil then
		for i = 1, n do
			window.values[i] = 0
		end
		window.lastDay = day
		return
	end
	if day <= window.lastDay then
		return
	end
	for i = 1, math.min(day - window.lastDay, n) do
		window.values[(window.lastDay + i) % n + 1] = 0
	end
	window.lastDay = day
end

function balancer.add(window, day, amount)
	balancer.advance(window, day)
	local slot = day % balancer.WINDOW_DAYS + 1
	window.values[slot] = window.values[slot] + amount
end

function balancer.sum(window)
	local total = 0
	for _, value in ipairs(window.values) do
		total = total + value
	end
	return total
end

-- capacity is the free space the line's departures offered at the hub over the window, not one vehicle's size.
function balancer.allocate(inflow, lines)
	local alloc, saturated, open = {}, {}, {}
	for _, line in ipairs(lines) do
		alloc[line.key] = 0
		if line.weight > 0 and line.capacity > 0 then
			open[#open + 1] = line
		end
	end

	local remaining = math.max(0, inflow)
	while remaining > 0 and #open > 0 do
		local weightSum = 0
		for _, line in ipairs(open) do
			weightSum = weightSum + line.weight
		end

		local stillOpen = {}
		for _, line in ipairs(open) do
			if remaining * line.weight / weightSum >= line.capacity then
				saturated[line.key] = true
			else
				stillOpen[#stillOpen + 1] = line
			end
		end

		if #stillOpen == #open then
			for _, line in ipairs(open) do
				alloc[line.key] = remaining * line.weight / weightSum
			end
			remaining = 0
		else
			for _, line in ipairs(open) do
				if saturated[line.key] then
					alloc[line.key] = line.capacity
					remaining = remaining - line.capacity
				end
			end
			open = stillOpen
		end
	end

	return alloc, saturated, remaining
end

function balancer.pressure(fill)
	if fill == nil then
		return 0
	end
	return clamp((fill - balancer.PRESSURE_START) / (balancer.PRESSURE_FULL - balancer.PRESSURE_START), 0, 1)
end

function balancer.compute(input)
	local alloc, saturated, leftover = balancer.allocate(input.inflow, input.lines)
	local pressure = balancer.pressure(input.fill)
	local result = {}

	for _, line in ipairs(input.lines) do
		local target = alloc[line.key]
		local correction = line.correction or 1
		local maxLoad
		if line.weight <= 0 then
			maxLoad = 0
		elseif line.capacity <= 0 then
			maxLoad = 1
		else
			local carried = line.carried or 0
			maxLoad = (target * correction + carried) / (line.capacity + carried)
			if maxLoad < 1 and pressure == 0 and not saturated[line.key] then
				correction = balancer.updateCorrection(correction, target, line.picked)
			end
		end
		maxLoad = clamp(maxLoad + (1 - maxLoad) * pressure, 0, 1)

		result[line.key] = {
			maxLoad = maxLoad,
			target = target,
			saturated = saturated[line.key] == true,
			correction = correction,
		}
	end

	local overflow = leftover >= 1 and next(saturated) ~= nil
	for _, line in ipairs(input.lines) do
		if line.weight > 0 and not saturated[line.key] then
			overflow = false
		end
	end

	return result, overflow
end

-- Called once per tick; the gain is small because picked lags the setting by up to a full window.
function balancer.updateCorrection(correction, target, picked)
	correction = correction or 1
	if target <= 0 or picked < balancer.MIN_FEEDBACK_SAMPLE then
		return correction
	end
	local step = (target / picked) ^ balancer.CORRECTION_GAIN
	return clamp(correction * step, balancer.CORRECTION_MIN, balancer.CORRECTION_MAX)
end

function balancer.needsUpdate(current, wanted)
	if current == nil then
		return true
	end
	if wanted == 0 or wanted == 1 then
		return current ~= wanted
	end
	return math.abs(wanted - current) >= balancer.MIN_CHANGE
end

return balancer
