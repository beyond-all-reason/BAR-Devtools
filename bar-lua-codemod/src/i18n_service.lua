local function _findI18nBase()
	local luxDirs = VFS.SubDirs('.lux/5.1/', VFS.RAW_ONLY) or {}
	for _, dir in ipairs(luxDirs) do
		if dir:match('i18n@') then
			local initPath = dir .. 'src/i18n/init.lua'
			if VFS.FileExists(initPath, VFS.RAW_ONLY) then
				return dir .. 'src/'
			end
		end
	end
	error("i18n library not found. Run 'lx sync' to install dependencies.")
end

local _origRequire = require
do
	local _loaded = {}
	local _base = _findI18nBase()
	require = function(modname)
		if _loaded[modname] then return _loaded[modname] end
		local rel = modname:gsub("%.", "/")
		local path = _base .. rel .. "/init.lua"
		if not VFS.FileExists(path, VFS.RAW_FIRST) then
			path = _base .. rel .. ".lua"
		end
		local src = VFS.LoadFile(path, VFS.RAW_FIRST)
		if not src then error("module '" .. modname .. "' not found at " .. path) end
		local chunk = assert(loadstring(src, path))
		local result = chunk(modname)
		_loaded[modname] = result or true
		return _loaded[modname]
	end
end
local i18n = require("i18n")
require = _origRequire

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
