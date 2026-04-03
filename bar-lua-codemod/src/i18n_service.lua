function i18n.loadFile(path)
	local success, data = pcall(function()
		local chunk = VFS.LoadFile(path, VFS.ZIP_FIRST)
		return assert(loadstring(chunk))()
	end)
	if not success then
		Spring.Log("i18n", LOG.ERROR, "Failed to parse file " .. path)
		Spring.Log("i18n", LOG.ERROR, data)
		return nil
	end
	i18n.load(data)
end

local _translate = i18n.translate
local missingTranslations = {}
function i18n.translate(key, data)
	local result = _translate(key, data)
	if result ~= nil then return result end
	if not missingTranslations[key] then
		missingTranslations[key] = true
		Spring.Log("i18n", "notice", 'No translation found for "' .. key .. '"')
	end
	return (data and data.default) or key
end

function i18n.unitName(unitDefName, data)
	data = data or {}
	if Spring.GetConfigInt("language_english_unit_names", 1) == 1 then
		data.locale = "en"
	end
	return i18n.translate("units.names." .. unitDefName, data)
end
