# Partial Load Balancing (Transport Fever 3 mod)

Splits a warehouse's stock across several lines by weight, for hub-and-spoke networks. Example: three lines pick up stone at the same hub, and you want them to take 20 %, 50 % and 30 % of it.

## How it works

The game script (`content/partial_load/partial_load.script.lua`) runs every simulation step and does the following:

1. It notes when a balanced line's vehicle arrives at the hub stop, and how much of the cargo it already carries.
2. When the vehicle leaves, it records three numbers in 30 daily buckets per line: what was loaded, the free capacity it offered, and the cargo it already had on board.
3. It measures the hub's inflow as `Δstock + pickups`, also over 30 days.
4. Four times a game day it computes each line's target:
   - **Split by weight.** `target = weight share × inflow`.
   - **Hand on the surplus.** A line whose target is more than the free capacity it offered is capped at that capacity. Its surplus goes to the other lines by weight, repeated until no further line hits its limit.
   - **Set the max load.** `maxLoad = (target × correction + carried) / (free + carried)`. Max load caps a vehicle's total load, so cargo already on board has to be counted in. The correction is a slow integral term that removes leftover error from rounding and waiting for stock. It doesn't build up while a line is saturated, already at 100 %, or under stock pressure.
   - **Stock pressure.** From 70 % fill of the warehouse stock that holds this cargo, every line is pushed towards 100 %, and reaches it at 95 %. Fill counts every cargo in that stock, because a mixed stock's capacity is shared.
5. It compares the result with the hub stop's **actual** max load (`StopConfig.maxLoad`). It sends `makeLineUpdateCmd` only when they differ by 0.05 or more, or when the result is exactly 0 or 1 and the stop isn't. Because it compares against the line itself, a manual edit or an update lost to another one gets corrected on the next tick. Lines that can't carry the cargo are never written. If a line visits the hub twice, the extra hub stops are set to 100 %.
6. The first time it writes to a line with automatic cargo filters, it switches that line to custom filters and remembers doing so. Unticking the checkbox sets the hub stops back to 100 % and hands automatic filters back to those lines.

The pure math is in `content/partial_load/balancer.lua` and doesn't use the game API.

## Loading the mod and testing it in game

### 1. Install

1. Open the user data folder: main menu → **Settings → Advanced → Open User Data Folder**. On Steam for Windows, the staging area is `C:\Program Files (x86)\Steam\userdata\<steam id>\3493540\local\staging_area\`.
2. Copy the folder `mzeiher_partial_load/` (the one containing `mod.json`) into `staging_area/`. Only that folder belongs there, not `tests/` or this README.
3. Start the game. The mod shows up under **Mod Hub → My Mods**. Run the validator there first, and fix any error it reports before going further.

### 2. Activate it

Mods are activated per game. Start a **new game** and tick **Partial Load Balancing** in the mod list, or tick it in the mod selection when you **load a savegame**. The mod affects the simulation, so achievements are off while it's active.

### 3. Build a small test hub

A sandbox or free game with lots of money is easiest:

1. Place a **warehouse** with its loading station, and feed it one cargo (stone, say) with a supply line from an industry.
2. Build three spoke lines that pick up at the warehouse's station and deliver elsewhere. Use different distances or vehicle types, for example a short truck line, a long train line and an air line.
3. Set each spoke line's hub stop to **Load if Available** in the line's cargo filter.
4. Let it run a month without the mod's balancing, and note the split the warehouse window shows.

### 4. Check, in this order

Each step tests one assumption from [Not yet verified in game](#not-yet-verified-in-game). If one fails, note which step it was, because the later steps depend on it.

| # | Do | Expect | If it fails |
|---|----|--------|-------------|
| 1 | Open the warehouse window | A **Partial Load Balancing** card appears | The plugin files didn't load (assumption 1). Look in the game log for errors mentioning `hub_card`. |
| 2 | Look at the card's line table | All three spoke lines are listed | The warehouse's station isn't part of its construction (assumption 2) |
| 3 | Look at the warnings | No "Load if Available" warning for lines you set that way | The LoadMode enum path is wrong (assumption 5) |
| 4 | Look at the stock bar | Same numbers as the base game's **Stocks** card | Stock lookup is wrong (assumption 6) |
| 5 | Set weights 20 / 50 / 30 and tick **Balance this cargo** | Within a few game days, **Max load** shows values for lines whose vehicles have left the hub | No values: departures aren't detected (assumption 3). Inspect a vehicle at the hub with the console commands below. |
| 6 | Open a spoke line's cargo filter for the hub stop | Max fill level matches the card's **Max load** | Wrong array index (assumption 4) |
| 7 | Watch a throttled vehicle at the hub | It leaves at about `capacity × max load`, not full | The game doesn't honour max load with "Load if Available" (assumption 4) |
| 8 | Change the max load by hand on a hub stop | It goes back to the card's value within a quarter day | — |
| 9 | Run 6–12 game months | **Actual** settles near **Target** (±3 %) | Normal for the first months; see Limitations |
| 10 | Untick **Balance this cargo** | Hub stops back at 100 %; lines that had automatic filters have them again | Assumption 8 |
| 11 | Save, load the save, keep running | Balancing continues; **Actual** doesn't jump | — |

### 5. Look inside with the console

The docs don't say how to open the in-game console, so check the game's key bindings. `debugPrint` prints tables to the console and the log file.

```lua
-- all warehouses and your lines
debugPrint(api.engine.getEntitiesWithComponent(api.type.ComponentType.WAREHOUSE))
debugPrint(api.engine.system.lineSystem.getLinesForPlayer(api.engine.util.getPlayer()))

-- the mod's saved state: groups, weights, windows, current max loads
debugPrint(api.engine.getComponent(
    api.engine.system.gameScriptSystem.getEntityForGameScript("mzeiher_partial_load::/partial_load/partial_load.gs"),
    api.type.ComponentType.GAME_SCRIPT).state)

-- a line's stops and their cargo filters (replace 12345)
debugPrint(api.engine.getComponent(12345, api.type.ComponentType.LINE).stops)

-- a vehicle at the hub: stopIndex should be the hub stop, counted from 0 (replace 23456)
local tv = api.engine.getComponent(23456, api.type.ComponentType.TRANSPORT_VEHICLE)
debugPrint({ state = tv.state, stopIndex = tv.stopIndex, caps = tv.config.allCaps })
```

### 6. Iterate

The copy in the staging area is the one the game loads, even if the mod is also published. After editing a file, reload the savegame so the scripts load again. The docs don't describe hot reloading.

## Limitations

- **It's slow to settle.** In the simulation test it takes about a year of game time to settle within ±3 %, because every measurement is a 30-day window.
- **Integer loads make it noisy.** Over any single 30-day window, a line with few, large vehicles swings by about ±10 %.
- **Lines that also unload at the hub.** If a line unloads and loads the same cargo at the hub, its pickups are undercounted.
- **Lines that aren't balanced.** If other lines pick up the same cargo at the hub, what they take counts as lower inflow, so they effectively go first.
- **Only one controlled stop per line.** If a line stops at the hub twice, only the first visit is controlled; the others are held at 100 %.
- **Manual changes are overwritten.** Any max load you set yourself on a balanced hub stop is overwritten within a quarter day. Untick the checkbox to give the stops back.
- **Removing the mod keeps the last values.** The hub stops keep their last max load. Untick the checkbox before you remove the mod.

## Not yet verified in game

Everything was written against the reference at <https://tf3-docs.transportfever.net/en/>. These points come from the docs and haven't been checked in a running game:

1. Plain-Lua `.script.lua` files referenced as `file.script@name`, for the game script and the GUI plugins, return their table from `function data()`, like `mod.script.lua`.
2. The lines at a warehouse are found through `Warehouse.construction → Construction.stations → station group`. If the warehouse's loading station isn't part of its construction, the card says "No line stops at a station of this warehouse".
3. `TransportVehicle.stopIndex` is zero-based and is the current stop while the vehicle is `AT_TERMINAL`.
4. `StopConfig.load` and `StopConfig.maxLoad` are Lua arrays indexed by cargo type id + 1, and vehicles leave a "Load if Available" stop once they reach `capacity × maxLoad`.
5. `api.type.Line.LoadMode.LOAD_IF_AVAILABLE` is the right way to reach the enum. If it isn't, the hub card warns about Full Load on every line.
6. `simEntityAtStockSystem.getStockCountForCargoType` and `getStockCount` take the stock list entity, as the base game's `cargo_util` does.
7. A line update sent while a vehicle is loading takes effect without disturbing the vehicle.
8. While a balanced line uses the custom filters the mod switched on, every stop config gets full `load` and `maxLoad` arrays: "load" and 100 % for every cargo type wherever an entry was missing. Unticking hands automatic filters back.
9. If commands are queued rather than run immediately, two updates to the same line in one tick (one line balanced for two cargos) can overwrite each other. The compare against the line's actual values corrects that on the next tick.

## Tests

```sh
lua tests/balancer_test.lua     # allocation, surplus redistribution, correction, pressure, windows
lua tests/script_sim_test.lua   # the real game script against a stubbed engine and a simulated hub
```

`script_sim_test.lua` runs the game script against a stubbed engine API. The hub gets 20 units a day and is served by a truck line, a train line and a plane line. It checks:

- after 480 days, the 90-day split is 20/50/30 (±3 %);
- a line without enough capacity hands its surplus on;
- cargo already on board is accounted for by the formula, not the correction;
- unticking the checkbox restores full load and automatic filters, even after the line's stops changed;
- an earlier hub stop takes over and the old one is released;
- manual edits are overwritten;
- lines that can't carry the cargo are never touched;
- dragging a weight slider doesn't add balancing steps;
- turning balancing off and on, loading an earlier save, or removing a vehicle at the hub doesn't record phantom pickups;
- a warehouse filled by its own or by other cargo opens every line.

A baseline run without the mod confirms the split isn't 20/50/30 on its own. Each check fails when the fix it covers is reverted.
