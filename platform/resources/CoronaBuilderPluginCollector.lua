------------------------------------------------------------------------------
--
-- This file is part of the Corona game engine.
-- For overview and more information on licensing please refer to README.md 
-- Home page: https://github.com/coronalabs/corona
-- Contact: support@coronalabs.com
--
------------------------------------------------------------------------------

local json = require "json"
local lfs = require "lfs"

local debugBuildProcess = os.execute("exit $(defaults read com.coronalabs.Corona_Simulator debugBuildProcess 2>/dev/null || echo 0)")
function log(...)
    if debugBuildProcess > 1 then
        print(...)
    end
end

local function quoteString( str )
    str = str:gsub('\\', '\\\\')
    str = str:gsub('"', '\\"')
    return "\"" .. str .. "\""
end

local function exec(cmd)
    log('Running command', cmd)
    if debugBuildProcess < 1 then
        cmd = cmd .. ' &> /dev/null'
    end
    assert(0 == os.execute(cmd))
end

local pluginLocatorCoronaStore =  {}
function pluginLocatorCoronaStore:init(params)
    self.user = params.user
    if not self.user  then
        return
    end
    self.http = require( "socket.http" )
    self.serverBackend = 'https://backendapi.coronalabs.com'

    local authURL = self.serverBackend .. '/v1/plugins/show/' .. self.user
	local authorisedPluginsText, msg = self.http.request(authURL)

	if not authorisedPluginsText then
		return false
	end

	local authPluginsJson = json.decode( authorisedPluginsText )
	if not authPluginsJson then
		return false
	end

	if authPluginsJson.status ~= 'success' then
		return false
	end

	if not authPluginsJson.data then
		return false
	end
    
    self.authorizedPlugins = {}

    for _, ap in pairs(authPluginsJson.data) do
        local pluginName = ap['plugin_name']
        local pluginDeveloper = ap["plugin_developer"]
        self.authorizedPlugins[pluginName] = self.authorizedPlugins[pluginName] or {}
        self.authorizedPlugins[pluginName][pluginDeveloper] = true
	end
	return true
end

function pluginLocatorCoronaStore:collect(destination, plugin, pluginTable, pluginPlatform, params)
    if not self.user then
        return "Corona Store: no user login"
    end
    if not self.authorizedPlugins then
        return "Corona Store: authorized plugins was not fetched"
    end
    local developer = pluginTable.publisherId
    if not (self.authorizedPlugins[plugin] or {})[developer] then
        return "Corona Store: plugin " .. plugin .. " was not authorized by the store. Activate at: https://marketplace.coronalabs.com/plugin/" .. developer .. "/" .. plugin
    end

    local build = params.build
    local downloadInfoURL = self.serverBackend .. '/v1/plugins/download/' .. developer .. '/' .. plugin .. '/' .. build .. '/' .. pluginPlatform

    local downloadInfoText, msg = self.http.request(downloadInfoURL)
    if not downloadInfoText then
        return "Corona Store: unable to fetch plugin download location for " .. plugin .. ' ('.. developer.. '). Error message: ' .. msg 
    end

    local downloadInfoJSON = json.decode(downloadInfoText)
    local downloadURL = downloadInfoJSON.url
    if not downloadURL then
        return "Corona Store: unable to parse plugin download location for " .. plugin .. ' ('.. developer.. ').'
    end

    local buildStr = downloadURL:match('/(%d%d%d%d%.%d%d%d%d)/')
    local file, err = self.http.request(downloadURL)
    if err == 404 then
        log("Corona Store: plugin " .. plugin .. " is not supported by the platform!")
        return true
    elseif err ~= 200 then
        return "Corona Store: unable to download " .. plugin .. ' ('.. developer.. '). Code: ' .. err .. 'Error message: \n' .. file
    end

    local pluginArchivePath = params.pluginStorage .. '/' .. pluginTable.publisherId .. '/' .. plugin .. '/' .. buildStr .. '/' .. pluginPlatform
    exec('/bin/mkdir -p ' .. quoteString(pluginArchivePath))
    pluginArchivePath = pluginArchivePath .. '/data.tgz'

    fi = io.open(pluginArchivePath, "wb")
    if (fi == nil) then
        return 'Corona Store: unable to create tgz'
    end
    fi:write(file)
    fi:close()
    
    exec('/bin/mkdir -p ' .. quoteString(destination))
    exec('/bin/cp ' .. quoteString(pluginArchivePath) .. ' ' ..  quoteString(destination) )
    return true
end


local function pluginLocatorCustomURL(destination, plugin, pluginTable, pluginPlatform, params)
    if type(pluginTable.supportedPlatforms) ~= 'table' then
        return "Custom URL: skipped because no table supportedPlatforms provided for " .. plugin
    end
    if type(pluginTable.supportedPlatforms[pluginPlatform]) ~= 'table' then
        log("Custom URL: skipped because supportedPlatforms[" .. pluginPlatform .. "] is not a table. Plugin is not supported by the platform")
        return true
    end
    if type(pluginTable.supportedPlatforms[pluginPlatform].url) ~= 'string' then
        return "Custom URL: skipped because supportedPlatforms[" .. pluginPlatform .. "].url is not a string"
    end

    exec('/bin/mkdir -p ' .. quoteString(destination))
    exec('curl -sS  -o ' .. quoteString(destination .. '/data.tgz') .. ' ' ..  quoteString(pluginTable.supportedPlatforms[pluginPlatform].url))
    return true
end


local function pluginLocatorFileSystemVersionized(destination, plugin, pluginTable, pluginPlatform, params)
    if type(pluginTable.publisherId) ~= 'string' then
        return "Locally: plugin has no string publisherId"
    end
    local pluginStorage = params.pluginStorage
    local pluginDir = pluginStorage .. '/' .. pluginTable.publisherId .. '/' .. plugin
    if lfs.attributes(pluginDir, 'mode') ~= 'directory' then
        return "Locally: no directory " .. pluginDir
    end
    local targetBuild = tonumber(params.build)
    local lastFound = -1
    local foundDir
    for file in lfs.dir(pluginDir) do
        if file ~= "." and file ~= ".." then
            local f = pluginDir..'/'..file
            if lfs.attributes(f, 'mode') == 'directory' then
                local dirBuild = file:match('^%d+%.(%d+)$')
                if dirBuild then
                    dirBuild = tonumber(dirBuild)
                    if dirBuild > lastFound and dirBuild <= targetBuild then
                        lastFound = dirBuild
                        foundDir = f
                    end 
                end
            end
        end
    end
    if not foundDir then
        return "Locally: didn't find suitable version in " .. pluginDir
    end
    local localPath = foundDir .. '/' .. pluginPlatform .. '/data.tgz'
    if lfs.attributes(localPath, 'mode') == 'file' then
        exec('/bin/mkdir -p ' .. quoteString(destination))
        exec('/bin/cp ' .. quoteString(localPath) .. ' ' ..  quoteString(destination) )
    else
        -- if we found suitable version, but no platform directory, it means plugin is not supported
        log('Local lookup determined that plugin ' .. plugin .. ' is not supported by the platform in this version ' ..  pluginPlatform)
    end
    return true
end


local function pluginLocatorFileSystemAllPlatforms(destination, plugin, pluginTable, pluginPlatform, params)
    if type(pluginTable.publisherId) ~= 'string' then
        return "Locally: plugin has no string publisherId"
    end
    local pluginStorage = params.pluginStorage
    local localPath = pluginStorage .. '/' .. pluginTable.publisherId .. '/' .. plugin .. '/data.tgz'
    if lfs.attributes(localPath, 'mode') == 'file' then
        exec('/bin/mkdir -p ' .. quoteString(destination))
        exec('/bin/cp ' .. quoteString(localPath) .. ' ' ..  quoteString(destination) )
        return true
    else
        return "Locally: no file '".. localPath .. "'"
    end
end

local function pluginLocatorFileSystem(destination, plugin, pluginTable, pluginPlatform, params)
    if type(pluginTable.publisherId) ~= 'string' then
        return "Locally: plugin has no string publisherId"
    end
    local pluginStorage = params.pluginStorage
    local localPath = pluginStorage .. '/' .. pluginTable.publisherId .. '/' .. plugin .. '/' .. pluginPlatform .. '/data.tgz'
    if lfs.attributes(localPath, 'mode') == 'file' then
        exec('/bin/mkdir -p ' .. quoteString(destination))
        exec('/bin/cp ' .. quoteString(localPath) .. ' ' ..  quoteString(destination) )
        return true
    elseif lfs.attributes(pluginStorage .. '/' .. pluginTable.publisherId .. '/' .. plugin, 'mode') == 'directory' then
        log('Local lookup determined that plugin ' .. plugin .. ' is not supported by the platform ' ..  pluginPlatform)
    else
        return "Locally: no file '".. localPath .. "'"
    end
end


local initializedLocators = false
local function fetchSinglePlugin(dstDir, plugin, pluginTable, pluginPlatform, params, pluginLocators)
    if type(pluginTable.supportedPlatforms) == 'table' and not pluginTable.supportedPlatforms[pluginPlatform] then
        return
    end
    if not initializedLocators then
        initializedLocators = true
        for i = 1,#pluginLocators do
            local locator = pluginLocators[i]
            if type(locator) == 'table' and type(locator.init) == 'function' then
                locator:init(params)
                if type(locator.collect) ~= 'function' then
                    return "ERROR: Plugin Locator #" .. tostring(i) .. " does not have :collect() method!"
                end
            elseif type(locator) ~= 'function' then
                return "ERROR: Plugin Locator #" .. tostring(i) .. " is not a function!"
            end
        end
    end
    local pluginDestination = dstDir .. '/' .. plugin
    local err = "Unable to find plugin '" .. plugin .. "' in:"
    local ok =  false
    for i = 1,#pluginLocators do
        local locator = pluginLocators[i]
        local result
        if type(locator) == 'table' then
            result = locator:collect(pluginDestination, plugin, pluginTable, pluginPlatform, params)
        else
            result = locator(pluginDestination, plugin, pluginTable, pluginPlatform, params)
        end
        if result == true then
            ok = true
            break
        elseif type(result) == 'string' then
            err = err .. '\n\t' .. result
        end
    end
    if not ok then
        return err
    end
end

function CollectCoronaPlugins(params)
    log("Collecting plugins")

    local pluginLocators = { pluginLocatorFileSystemVersionized, pluginLocatorFileSystem, pluginLocatorFileSystemAllPlatforms, pluginLocatorCustomURL, pluginLocatorCoronaStore, }

    local dstDir = params.destinationDirectory

    params.pluginLocators = pluginLocators
    if not params.pluginStorage then
        params.pluginStorage = os.getenv("HOME") .. '/CoronaPlugins'
    end

    local plugins = json.decode(params.buildData).plugins
    if type(plugins) ~= 'table' then return end

    local pluginPlatform = params.pluginPlatform
    local collectedPlugins = {}
    for plugin, pluginTable in pairs(plugins) do
        assert(type(plugin) == 'string', "Plugin is not a string")
        assert(type(pluginTable) == 'table', 'Invalid plugin table for ' .. plugin)
        local result = fetchSinglePlugin(dstDir, plugin, pluginTable, pluginPlatform, params, pluginLocators)
        if type(result) == 'string'  then
            return result
        end
        collectedPlugins[plugin] = true
    end

    log("Collecting plugin dependencies")
    local unresolvedDeps = {}
    local allFetched
    repeat
        for plugin, pluginTable in pairs(unresolvedDeps) do
            log("Collecting dependency " .. plugin)
            local result = fetchSinglePlugin(dstDir, plugin, pluginTable, pluginPlatform, params, pluginLocators)
            if type(result) == 'string'  then
                return result
            end
            collectedPlugins[plugin] = true
        end
        unresolvedDeps = {}
        allFetched = true
        for plugin, _ in pairs(collectedPlugins)  do
            local pluginDestination = dstDir .. '/' .. plugin
            if 0 == os.execute('/usr/bin/tar -xzf ' .. quoteString(pluginDestination .. '/data.tgz') .. ' -C ' .. quoteString(pluginDestination) .. ' metadata.lua') then
                local toDownload = {}
                local metadataFile = pluginDestination .. "/metadata.lua"
                pcall( function()
                    local metadata = dofile(metadataFile)
                    toDownload = metadata.coronaManifest.dependencies
                end	)
                os.remove(metadataFile)
                if type(toDownload) == 'table' then
                    for depPlugin, depDeveloper in pairs(toDownload) do
                        if not collectedPlugins[depPlugin] then
                            unresolvedDeps[depPlugin] = {publisherId=depDeveloper}
                            allFetched = false
                        end
                    end
                end
            end
        end
    until allFetched
end


return {
    collect = CollectCoronaPlugins
}