local react = ug_require "::/gui/main/react.lua"
local builtin = ug_require "::/gui/main/builtin.lua"
local engine_react_util = ug_require "::/gui/main/engine_react_util.tl"
local content_card = ug_require "::/gui/main/content_card.tl"
local line_eow = ug_require "::/gui/entity_window/line/line_eow.script.tl"
local hub = ug_require "/partial_load/hub.lua"

local percent = hub.percent

local function makeSummaries(lineEntity)
	local summaries = {}
	for _, group in pairs(hub.readState().groups or {}) do
		local entry = group.enabled and group.lines[tostring(lineEntity)]
		if entry then
			summaries[#summaries + 1] = string.format(
				_("%s at %s: target %s · actual %s · max load %s"),
				hub.cargoName(group.cargo),
				hub.warehouseName(group.warehouse),
				percent(entry.targetShare),
				percent(entry.actualShare),
				entry.maxLoad and percent(entry.maxLoad) or "–"
			)
		end
	end
	table.sort(summaries)
	return summaries
end

local LineCardContent = react.RegisterRecipe("PartialLoadLineCardContent", function(params)
	local children = {}
	for _, summary in ipairs(params.summaries) do
		children[#children + 1] = builtin.TextView{ text = summary }
	end
	children[#children + 1] = content_card.makeInfoHint(_("The hub stop's max load is set by the Partial Load mod; manual changes are overwritten."), true)

	return builtin.BoxLayout{
		orientation = builtin.type.Orientation.Vertical,
		children = children,
	}
end)

local LineCardPlugin = react.RegisterPluginRecipe(line_eow.LineEowExtensionPoint, "PartialLoadLineCardPlugin", function(params)
	local summaries = engine_react_util.useStepStateTimer(function()
		return makeSummaries(params.entityId)
	end, 1.0):old()
	if #summaries == 0 then
		return nil
	end
	return builtin.BoxLayout{
		child = content_card.ContentCard{
			title = _("Partial Load"),
			recipeAndParamPermanent = content_card.makeRecipeAndParam(LineCardContent, { summaries = summaries }),
			gameCtx = params.gameCtx,
			showOnRightSide = params.showCalloutOnRightSide,
		},
	}
end)

function data()
	return {
		LineCardPlugin = LineCardPlugin,
	}
end
