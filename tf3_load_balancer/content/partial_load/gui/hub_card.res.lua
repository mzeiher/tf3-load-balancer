function data()
	return {
		type = "react-plugin ::WarehouseEowExtensionPoint",
		data = {
			filePath = "mzeiher_partial_load::/partial_load/gui/hub_card.script@HubCardPlugin",
			condition = "::/gui/entity_window/warehouse/warehouse_eow.script@isModifiable",
			order = 25,
		},
	}
end
