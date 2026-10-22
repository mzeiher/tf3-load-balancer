package.path = "mzeiher_partial_load/content/partial_load/?.lua;" .. package.path
local balancer = require("balancer")

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

local function near(actual, expected, label)
	if math.abs(actual - expected) > 1e-9 then
		error(string.format("%s: expected %.6f, got %.6f", label, expected, actual), 2)
	end
end

local function line(key, weight, capacity, picked)
	return { key = key, weight = weight, capacity = capacity, picked = picked or 0 }
end

test("splits inflow by weight when every line has room", function()
	local alloc, saturated, leftover = balancer.allocate(600, {
		line("A", 20, 400), line("B", 50, 400), line("C", 30, 300),
	})
	near(alloc.A, 120, "A")
	near(alloc.B, 300, "B")
	near(alloc.C, 180, "C")
	assert(next(saturated) == nil, "nothing saturated")
	near(leftover, 0, "leftover")
end)

test("gives a saturated line's surplus to the others by weight", function()
	local alloc, saturated, leftover = balancer.allocate(600, {
		line("A", 20, 400), line("B", 50, 200), line("C", 30, 300),
	})
	near(alloc.A, 160, "A")
	near(alloc.B, 200, "B")
	near(alloc.C, 240, "C")
	assert(saturated.B and not saturated.A and not saturated.C, "only B saturated")
	near(leftover, 0, "leftover")
end)

test("cascades when the redistributed surplus saturates another line", function()
	local alloc, saturated, leftover = balancer.allocate(600, {
		line("A", 20, 150), line("B", 50, 200), line("C", 30, 400),
	})
	near(alloc.A, 150, "A")
	near(alloc.B, 200, "B")
	near(alloc.C, 250, "C")
	assert(saturated.A and saturated.B and not saturated.C, "A and B saturated")
	near(leftover, 0, "leftover")
end)

test("reports leftover when every line is at capacity", function()
	local alloc, saturated, leftover = balancer.allocate(1000, {
		line("A", 1, 100), line("B", 1, 200),
	})
	near(alloc.A, 100, "A")
	near(alloc.B, 200, "B")
	assert(saturated.A and saturated.B, "both saturated")
	near(leftover, 700, "leftover")
end)

test("zero-weight and unmeasured lines get no allocation", function()
	local alloc = balancer.allocate(600, {
		line("A", 0, 400), line("B", 10, 0), line("C", 10, 1000),
	})
	near(alloc.A, 0, "A")
	near(alloc.B, 0, "B")
	near(alloc.C, 600, "C")
end)

test("negative inflow allocates nothing", function()
	local alloc, _, leftover = balancer.allocate(-50, { line("A", 1, 100) })
	near(alloc.A, 0, "A")
	near(leftover, 0, "leftover")
end)

test("maxLoad is target over offered capacity", function()
	local result, overflow = balancer.compute({
		inflow = 600,
		lines = { line("A", 20, 400), line("B", 50, 200), line("C", 30, 300) },
	})
	near(result.A.maxLoad, 0.4, "A")
	near(result.B.maxLoad, 1.0, "B")
	near(result.C.maxLoad, 0.8, "C")
	assert(result.B.saturated, "B saturated")
	assert(not overflow, "no overflow")
end)

test("cargo already on board raises maxLoad by what it occupies", function()
	local a = line("A", 1, 300)
	a.carried = 100
	local result = balancer.compute({ inflow = 120, lines = { a } })
	near(result.A.maxLoad, (120 + 100) / (300 + 100), "A")
end)

test("overflow only when every weighted line is saturated", function()
	local _, full = balancer.compute({ inflow = 1000, lines = { line("A", 1, 100), line("B", 1, 200) } })
	assert(full, "all saturated")
	local _, unmeasured = balancer.compute({ inflow = 1000, lines = { line("A", 1, 100), line("B", 1, 0) } })
	assert(not unmeasured, "B has no data yet")
	local _, closed = balancer.compute({ inflow = 1000, lines = { line("A", 0, 100), line("B", 0, 200) } })
	assert(not closed, "all weights zero")
	local _, nothing = balancer.compute({ inflow = 1000, lines = {} })
	assert(not nothing, "no lines")
end)

test("zero weight closes the line, missing capacity data opens it fully", function()
	local result = balancer.compute({
		inflow = 600,
		lines = { line("A", 0, 400), line("B", 10, 0), line("C", 10, 600) },
	})
	near(result.A.maxLoad, 0, "A")
	near(result.B.maxLoad, 1, "B")
	near(result.C.maxLoad, 1, "C")
end)

test("correction grows while a line picks up less than its target", function()
	local correction = balancer.updateCorrection(nil, 120, 60)
	near(correction, 2 ^ balancer.CORRECTION_GAIN, "one step")
	assert(balancer.updateCorrection(correction, 120, 60) > correction, "keeps growing")
	assert(balancer.updateCorrection(1, 60, 120) < 1, "shrinks when over target")
end)

test("correction is bounded and ignores small samples", function()
	near(balancer.updateCorrection(balancer.CORRECTION_MAX, 1000, 20), balancer.CORRECTION_MAX, "upper bound")
	near(balancer.updateCorrection(balancer.CORRECTION_MIN, 20, 1000), balancer.CORRECTION_MIN, "lower bound")
	near(balancer.updateCorrection(1.3, 120, balancer.MIN_FEEDBACK_SAMPLE - 1), 1.3, "small sample")
end)

test("compute applies the correction and returns the next one", function()
	local a = line("A", 20, 400, 60)
	a.correction = 1.5
	local result = balancer.compute({ inflow = 600, lines = { a, line("C", 80, 1000, 480) } })
	near(result.A.target, 120, "A target")
	near(result.A.maxLoad, 0.3 * 1.5, "A maxLoad")
	near(result.A.correction, 1.5 * 2 ^ balancer.CORRECTION_GAIN, "A next correction")
	near(result.C.correction, 1, "C on target")
end)

test("correction does not wind up while saturated, full or under pressure", function()
	local b = line("B", 50, 200, 100)
	b.correction = 1.2
	local saturatedResult = balancer.compute({ inflow = 600, lines = { line("A", 20, 400), b } })
	assert(saturatedResult.B.saturated, "B saturated")
	near(saturatedResult.B.correction, 1.2, "saturated")

	local c = line("C", 10, 100, 30)
	c.correction = 1.9
	local fullResult = balancer.compute({ inflow = 120, lines = { c, line("D", 10, 1000) } })
	near(fullResult.C.maxLoad, 1, "capped at full load")
	near(fullResult.C.correction, 1.9, "full")

	local e = line("E", 10, 400, 30)
	local pressured = balancer.compute({ inflow = 120, fill = 0.9, lines = { e } })
	near(pressured.E.correction, 1, "pressure")
end)

test("stock pressure pushes every line towards full load", function()
	local lines = { line("A", 20, 400), line("C", 80, 1000) }
	local calm = balancer.compute({ inflow = 600, fill = 0.5, lines = lines })
	local half = balancer.compute({ inflow = 600, fill = 0.825, lines = lines })
	local full = balancer.compute({ inflow = 600, fill = 0.99, lines = lines })
	near(calm.A.maxLoad, 0.3, "calm")
	near(half.A.maxLoad, 0.65, "half pressure")
	near(full.A.maxLoad, 1.0, "full pressure")
	near(full.C.maxLoad, 1.0, "full pressure C")
end)

test("window sums the last 30 days and forgets older ones", function()
	local window = balancer.newWindow()
	balancer.add(window, 100, 5)
	balancer.add(window, 100, 5)
	balancer.add(window, 110, 7)
	near(balancer.sum(window), 17, "within window")
	balancer.advance(window, 130)
	near(balancer.sum(window), 7, "day 100 expired")
	balancer.advance(window, 140)
	near(balancer.sum(window), 0, "day 110 expired")
end)

test("window clears fully after a gap longer than the window", function()
	local window = balancer.newWindow()
	for day = 1, 30 do
		balancer.add(window, day, 1)
	end
	near(balancer.sum(window), 30, "full")
	balancer.advance(window, 500)
	near(balancer.sum(window), 0, "gap")
	balancer.add(window, 500, 3)
	near(balancer.sum(window), 3, "after gap")
end)

test("window ignores days in the past", function()
	local window = balancer.newWindow()
	balancer.add(window, 50, 4)
	balancer.advance(window, 49)
	near(balancer.sum(window), 4, "unchanged")
end)

test("needsUpdate applies hysteresis but always reaches 0 and 1", function()
	assert(balancer.needsUpdate(nil, 0.5), "first value")
	assert(not balancer.needsUpdate(0.5, 0.53), "small change")
	assert(balancer.needsUpdate(0.5, 0.56), "large change")
	assert(balancer.needsUpdate(0.98, 1), "reach full")
	assert(balancer.needsUpdate(0.02, 0), "reach zero")
	assert(not balancer.needsUpdate(1, 1), "already full")
end)

print(string.format("%d passed, %d failed", passed, failures))
os.exit(failures == 0 and 0 or 1)
