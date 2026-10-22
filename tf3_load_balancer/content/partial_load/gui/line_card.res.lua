function data()
	return {
		type = "react-plugin ::LineEowExtensionPoint",
		data = {
			filePath = "mzeiher_partial_load::/partial_load/gui/line_card.script@LineCardPlugin",
			condition = "::/gui/entity_window/line/line_eow.script@conditionPlayerOwned",
			order = 25,
		},
	}
end
