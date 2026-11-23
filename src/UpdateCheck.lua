#@
-- Path of Building
--
-- Module: Update Check
-- Checks for updates
--
local connectionProtocol, proxyURL, noSSL = ...

local xml = require("xml")
local sha1 = require("sha1")
local curl = require("lcurl.safe")
local lzip = require("lzip")

local globalRetryLimit = 10
local function downloadFileText(source, file)
	for i = 1, 5 do
		if i > 1 then
			ConPrintf("Retrying... (%d of 5)", i)
		end
		local text = ""
		local easy = curl.easy()
		local escapedUrl = source..easy:escape(file)
		easy:setopt_url(escapedUrl)
		easy:setopt(curl.OPT_ACCEPT_ENCODING, "")
		easy:setopt(curl.OPT_CONNECTTIMEOUT, 20)
		easy:setopt(curl.OPT_LOW_SPEED_LIMIT, 1024)
		easy:setopt(curl.OPT_LOW_SPEED_TIME, 60)
		if connectionProtocol then
			easy:setopt(curl.OPT_IPRESOLVE, connectionProtocol)
		end
		if proxyURL then
			easy:setopt(curl.OPT_PROXY, proxyURL)
		end
		if noSSL then
			easy:setopt(curl.OPT_SSL_VERIFYPEER, 0)
			easy:setopt(curl.OPT_SSL_VERIFYHOST, 0)
			ConPrintf("SSL verification disabled")
		end
		easy:setopt_writefunction(function(data)
			text = text..data 
			return true
		end)
		local _, error = easy:perform()
		easy:close()
		if not error then
			return text
		end
		ConPrintf("Download failed (%s)", error:msg())
		if globalRetryLimit == 0 or i == 5 then
			return nil, error:msg()
		end
		globalRetryLimit = globalRetryLimit - 1
	end
end
local function downloadFile(source, file, outName)
	for i = 1, 5 do
		if i > 1 then
			ConPrintf("Retrying... (%d of 5)", i)
		end
		local easy = curl.easy()
		local escapedUrl = source..easy:escape(file)
		easy:setopt_url(escapedUrl)
		easy:setopt(curl.OPT_ACCEPT_ENCODING, "")
		easy:setopt(curl.OPT_CONNECTTIMEOUT, 20)
		easy:setopt(curl.OPT_LOW_SPEED_LIMIT, 1024)
		easy:setopt(curl.OPT_LOW_SPEED_TIME, 60)
		if connectionProtocol then
			easy:setopt(curl.OPT_IPRESOLVE, connectionProtocol)
		end
		if proxyURL then
			easy:setopt(curl.OPT_PROXY, proxyURL)
		end
		if noSSL then
			easy:setopt(curl.OPT_SSL_VERIFYPEER, 0)
			easy:setopt(curl.OPT_SSL_VERIFYHOST, 0)
			ConPrintf("SSL verification disabled")
		end
		local file = io.open(outName, "wb+")
		easy:setopt_writefunction(file)
		local _, error = easy:perform()
		easy:close()
		file:close()
		if not error then
			return true
		end
		ConPrintf("Download failed (%s)", error:msg())
		if globalRetryLimit == 0 or i == 5 then
			return nil, error:msg()
		end
		globalRetryLimit = globalRetryLimit - 1
	end
	return true
end

-- jsdelivr refuses any package over 50 MB and this fork's repository is far
-- larger, so a file it has not cached comes back as a short error page under
-- HTTP 200 instead of the file. raw has no size cap but rate-limits. Each
-- host's URL can be rewritten into the other's, so a failed mirror costs one
-- more attempt instead of the whole update.
local function mirroredSources(source)
	local owner, repo, branch, rest = source:match("^https://cdn%.jsdelivr%.net/gh/([^/]+)/([^/@]+)@([^/]+)/(.*)$")
	if owner then
		return { source, "https://raw.githubusercontent.com/"..owner.."/"..repo.."/"..branch.."/"..rest }
	end
	owner, repo, branch, rest = source:match("^https://raw%.githubusercontent%.com/([^/]+)/([^/]+)/([^/]+)/(.*)$")
	if owner then
		return { source, "https://cdn.jsdelivr.net/gh/"..owner.."/"..repo.."@"..branch.."/"..rest }
	end
	return { source }
end

local function fileMatches(path, expected)
	if not expected then
		return false
	end
	local file = io.open(path, "rb")
	if not file then
		return false
	end
	local content = file:read("*all")
	file:close()
	return expected == sha1(content) or expected == sha1(content:gsub("\n", "\r\n"))
end

ConPrintf("Checking for update...")

-- Use built-in helpers to obtain absolute paths without spawning a shell.
local scriptPath, scriptFallback = GetScriptPath()
scriptPath = scriptPath or scriptFallback or "."
local runtimePath, runtimeFallback = GetRuntimePath()
runtimePath = runtimePath or runtimeFallback or scriptPath

-- The released zip is flat: the manifest, the launcher and the program files
-- all share one folder. A source-tree run (src/ next to runtime/) puts the
-- manifest one level above the Lua files, which Launch.lua already accepts
-- (src/Launch.lua:93); accept it here too, or that run fails with "Invalid
-- local manifest".
local localManXML = xml.LoadXMLFile(scriptPath.."/manifest.xml")
local manifestDir = scriptPath
if not localManXML then
	local parentXML = xml.LoadXMLFile(scriptPath.."/../manifest.xml")
	if parentXML then
		localManXML = parentXML
		manifestDir = scriptPath.."/.."
	end
end

-- Where a manifest entry lives on disk. In the flat zip every part resolves to
-- the package folder; in the source tree the runtime sits in runtime/ and the
-- manifest's own part one level up. Both cases collapse to the same rule.
local function filePath(part, name)
	if part == "runtime" then
		return runtimePath .. "/" .. name
	elseif part == "default" then
		return manifestDir .. "/" .. name
	end
	return scriptPath .. "/" .. name
end

-- Load and process local manifest
local localVer
local localPlatform, localBranch
local localFiles = { }
local localSource
local runtimeExecutable
if localManXML and localManXML[1].elem == "PoBVersion" then
	for _, node in ipairs(localManXML[1]) do
		if type(node) == "table" then
			if node.elem == "Version" then
				localVer = node.attrib.number
				localPlatform = node.attrib.platform
				localBranch = node.attrib.branch
			elseif node.elem == "Source" then
				if node.attrib.part == "default" then
					localSource = node.attrib.url
				end
			elseif node.elem == "File" then
				local fullPath
				node.attrib.name = node.attrib.name:gsub("{space}", " ")
				fullPath = filePath(node.attrib.part, node.attrib.name)
				localFiles[node.attrib.name] = { sha1 = node.attrib.sha1, part = node.attrib.part, platform = node.attrib.platform, fullPath = fullPath }
				if node.attrib.part == "runtime" and node.attrib.name:match("Path of Building") then
					runtimeExecutable = fullPath
				end
			end
		end
	end
end
if not localVer or not localSource or not localBranch or not next(localFiles) then
	ConPrintf("Update check failed: invalid local manifest")
	return nil, "Invalid local manifest"
end
localSource = localSource:gsub("{branch}", localBranch)

-- Download and process remote manifest
local remoteVer
local remoteFiles = { }
local remoteSources = { }
local remoteManText, errMsg
for _, candidate in ipairs(mirroredSources(localSource)) do
	remoteManText, errMsg = downloadFileText(candidate, "manifest.xml")
	if remoteManText then
		break
	end
end
if not remoteManText then
	ConPrintf("Update check failed: couldn't download version manifest")
	return nil, "Couldn't download version manifest.\nReason: "..errMsg.."\nCheck your internet connectivity.\nIf you are using a proxy, specify it in Options."
end
local remoteManXML = xml.ParseXML(remoteManText)
if remoteManXML and remoteManXML[1].elem == "PoBVersion" then
	for _, node in ipairs(remoteManXML[1]) do
		if type(node) == "table" then
			if node.elem == "Version" then
				remoteVer = node.attrib.number
			elseif node.elem == "Source" then
				if not remoteSources[node.attrib.part] then
					remoteSources[node.attrib.part] = { }
				end
				remoteSources[node.attrib.part][node.attrib.platform or "any"] = node.attrib.url
			elseif node.elem == "File" then
				if not node.attrib.platform or node.attrib.platform == localPlatform then
					local fullPath = filePath(node.attrib.part, node.attrib.name)
					remoteFiles[node.attrib.name] = { sha1 = node.attrib.sha1, part = node.attrib.part, platform = node.attrib.platform, fullPath = fullPath }
				end
			end
		end
	end
end
if not remoteVer or not next(remoteSources) or not next(remoteFiles) then
	ConPrintf("Update check failed: invalid remote manifest")
	return nil, "Invalid remote manifest"
end

-- Build lists of files to be updated or deleted
local updateFiles = { }
for name, data in pairs(remoteFiles) do
	data.name = name
	local sanitizedName = name:gsub("{space}", " ")
	if (not localFiles[name] or localFiles[name].sha1 ~= data.sha1) and (not localFiles[sanitizedName] or localFiles[sanitizedName].sha1 ~= data.sha1) then
		table.insert(updateFiles, data)
	elseif localFiles[name] then
		local file = io.open(localFiles[name].fullPath, "rb")
		if not file then
			ConPrintf("Warning: '%s' doesn't exist, it will be re-downloaded", data.name)
			table.insert(updateFiles, data)
		else
			local content = file:read("*a")
			file:close()
			if data.sha1 ~= sha1(content) and data.sha1 ~= sha1(content:gsub("\n", "\r\n")) then
				ConPrintf("Warning: Integrity check on '%s' failed, it will be replaced", data.name)
				table.insert(updateFiles, data)
			end
		end
	end
end
local deleteFiles = { }
for name, data in pairs(localFiles) do
	data.name = name
	local unSanitizedName = name:gsub(" ", "{space}")
	if not remoteFiles[name] and not remoteFiles[unSanitizedName] then
		table.insert(deleteFiles, data)
	end
end
	
if #updateFiles == 0 and #deleteFiles == 0 then
	ConPrintf("No update available.")
	return "none"
end

MakeDir("Update")
ConPrintf("Downloading update...")

-- Download changelog. A mirror answering with an error page under HTTP 200
-- must not replace the changelog already on disk, so the fetched copy only
-- takes the old one's place once it matches the manifest.
local changelogPath = manifestDir.."/changelog.txt"
local changelogSha = remoteFiles["changelog.txt"] and remoteFiles["changelog.txt"].sha1
local changelogFetched = false
for _, candidate in ipairs(mirroredSources(localSource)) do
	downloadFile(candidate, "changelog.txt", changelogPath..".tmp")
	if fileMatches(changelogPath..".tmp", changelogSha) then
		os.remove(changelogPath)
		os.rename(changelogPath..".tmp", changelogPath)
		changelogFetched = true
		break
	end
end
if not changelogFetched then
	os.remove(changelogPath..".tmp")
	ConPrintf("Couldn't fetch the changelog; keeping the one already on disk")
end

-- Download files that need updating
local failedFile = false
local zipFiles = { }

-- One attempt at one host: fetch the file, or extract it from the part's zip,
-- and report whether what landed on disk matches the manifest.
local function fetchFromSource(source, data, fileName)
	local zipName = source:match("/([^/]+%.zip)$")
	if not zipName then
		if fileMatches(fileName, data.sha1) then
			ConPrintf("Using file from previous update attempt '%s'", fileName)
		else
			ConPrintf("Downloading %s...", data.name)
			downloadFile(source, data.name, fileName)
		end
		return fileMatches(fileName, data.sha1)
	end
	local zipFileName = scriptPath.."/Update/"..zipName
	if not zipFiles[zipFileName] then
		ConPrintf("Downloading %s...", zipName)
		downloadFile(source, "", zipFileName)
		zipFiles[zipFileName] = lzip.open(zipFileName)
	end
	local zip = zipFiles[zipFileName]
	if zip then
		local zippedFile = zip:OpenFile(data.name)
		if zippedFile then
			local file = io.open(fileName, "wb+")
			file:write(zippedFile:Read("*a"))
			file:close()
			zippedFile:Close()
		else
			ConPrintf("Couldn't extract '%s' from '%s' (extract failed)", data.name, zipName)
		end
	else
		ConPrintf("Couldn't extract '%s' from '%s' (zip open failed)", data.name, zipName)
	end
	if fileMatches(fileName, data.sha1) then
		return true
	end
	-- Truncated or the wrong archive: discard it so the next host starts clean.
	if zip then
		pcall(zip.Close, zip)
		zipFiles[zipFileName] = nil
	end
	os.remove(zipFileName)
	return false
end

for index, data in ipairs(updateFiles) do
	if UpdateProgress then
		UpdateProgress("Downloading %d/%d", index, #updateFiles)
	end
	-- A manifest can name a part the sources do not define (a runtime file
	-- next to a manifest whose Version carries no platform, for instance).
	-- That must fail this file, not the whole update thread.
	local partSources = remoteSources[data.part] or { }
	local source = partSources[localPlatform or "win32"] or partSources["any"]
	if not source then
		ConPrintf("No source for part '%s' (file '%s')", tostring(data.part), data.name)
		failedFile = true
		data.unresolved = true
	else
		source = source:gsub("{branch}", localBranch)
		local fileName = scriptPath.."/Update/"..data.name:gsub("[\\/]","{slash}")
		data.updateFileName = fileName
		local fetched = false
		for _, candidate in ipairs(mirroredSources(source)) do
			if fetchFromSource(candidate, data, fileName) then
				fetched = true
				break
			end
			ConPrintf("Source '%s' did not yield '%s'", candidate, data.name)
		end
		if not fetched then
			failedFile = true
		end
	end
end
for name, zip in pairs(zipFiles) do
	zip:Close()
	os.remove(name)
end
if failedFile then
	ConPrintf("Update failed: one or more files couldn't be downloaded")
	return nil, "One or more files couldn't be downloaded.\nCheck your internet connectivity,\nor try again later."
end

-- Create new manifest
localManXML = { elem = "PoBVersion" }
table.insert(localManXML, { elem = "Version", attrib = { number = remoteVer, platform = localPlatform, branch = localBranch } })
for part, platforms in pairs(remoteSources) do
	for platform, url in pairs(platforms) do
		table.insert(localManXML, { elem = "Source", attrib = { part = part, platform = platform ~= "any" and platform, url = url } })
	end
end
for name, data in pairs(remoteFiles) do
	table.insert(localManXML, { elem = "File", attrib = { name = data.name, sha1 = data.sha1, part = data.part, platform = data.platform } })
end 
xml.SaveXMLFile(localManXML, scriptPath.."/Update/manifest.xml")

-- Build list of operations to apply the update
local updateMode = "normal"
local ops = { }
local opsRuntime = { }
for _, data in pairs(updateFiles) do
	-- Ensure that the destination path of this file exists
	local dirStr = data.fullPath:sub(1,1) == "/" and "/" or ""
	for dir in data.fullPath:gmatch("([^/]+/)") do
		dirStr = dirStr .. dir
		MakeDir(dirStr)
	end
	if data.part == "runtime" then
		-- Core runtime file, will need to update from the basic environment
		-- These files will be updated on the second pass of the update script, with the first pass being run within the normal environment
		updateMode = "basic"
		table.insert(opsRuntime, 'move "'..data.updateFileName..'" "'..data.fullPath..'"')
	else
		table.insert(ops, 'move "'..data.updateFileName..'" "'..data.fullPath..'"')
	end
end
for _, data in pairs(deleteFiles) do
	table.insert(ops, 'delete "'..data.fullPath..'"')
end
table.insert(ops, 'move "'..scriptPath..'/Update/manifest.xml" "'..scriptPath..'/manifest.xml"')
if updateMode == "basic" then
	-- Update script will need to relaunch the normal environment after updating
	table.insert(opsRuntime, 'start "'..runtimeExecutable..'"')
	local opRuntimeFile = io.open(scriptPath.."/Update/opFileRuntime.txt", "w+")
	opRuntimeFile:write(table.concat(opsRuntime, "\n"))
	opRuntimeFile:close()
end

-- Write operations file
local opFile = io.open(scriptPath.."/Update/opFile.txt", "w+")
opFile:write(table.concat(ops, "\n"))
opFile:close()

ConPrintf("Update is ready.")
return updateMode
