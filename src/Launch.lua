#@ SimpleGraphic
-- Path of Building
--
-- Module: Launch
-- Program entry point; loads and runs the Main module within a protected environment
--

local startTime = GetTime()
APP_NAME = "Path of Building"

-- ==== i18n fork ============================================================
-- This build carries local internationalization work on top of upstream
-- Path of Building Community. It must NEVER self-update: the upstream manifest
-- points at raw.githubusercontent.com, and any file whose SHA1 differs from the
-- official release (i.e. every file we touch) is treated as corrupt and
-- re-downloaded, silently wiping the fork's changes.
--
-- Upstream changes are merged in git and re-released by the fork maintainer,
-- so the update paths are switched off rather than allowed to fail.
FORK_ID = "i18n"
FORK_NAME = "PoB i18n"
FORK_VERSION_SUFFIX = "-i18n.1"

SetWindowTitle(APP_NAME)
ConExecute("set vid_mode 8")
ConExecute("set vid_resizable 3")

---@diagnostic disable-next-line: lowercase-global
launch = { }
SetMainObject(launch)
jit.opt.start('maxtrace=4000','maxmcode=8192')
if os.getenv("POB_NO_JIT") then require("jit").off() print("JIT off via env") end
collectgarbage("setpause", 400)

-- Where the translation dictionaries live, if any are installed.
-- Search order: POB_I18N_DIRECTORY (explicit), then Data/<game>/ next to the
-- script folder, then next to the runtime. Returns nil when nothing is found,
-- and Load() then leaves every string in English.
local function find_i18n_dir()
	local candidates = { }
	local env = os.getenv("POB_I18N_DIRECTORY")
	if env and env ~= "" then candidates[#candidates + 1] = env end
	local scriptPath = GetScriptPath()
	if scriptPath then candidates[#candidates + 1] = scriptPath .. "/../Data/poe1" end
	local runtimePath = GetRuntimePath()
	if runtimePath then candidates[#candidates + 1] = runtimePath .. "/Data/poe1" end
	for _, dir in ipairs(candidates) do
		local probe = io.open(dir .. "/zh-rCN/meta.json", "rb")
		if probe then probe:close() return dir end
	end
	return nil
end

local function i18n_locale()
	local env = os.getenv("POB_I18N_LOCALE")
	if env and env ~= "" then return env end
	return "zh-rCN"
end

function launch:OnInit()
	self.devMode = false
	self.installedMode = false
	self.versionNumber = "?"
	self.versionBranch = "?"
	self.versionPlatform = "?"
	self.lastUpdateCheck = GetTime()
	self.subScripts = { }
	self.startTime = startTime
	-- Single gate for every update path (startup check, 12h check, Ctrl+U,
	-- the "Check for Update" button and the first-run bootstrap below).
	self.forkMode = true
	self.updatesDisabled = true
	local firstRunFile = io.open("first.run", "r")
	if firstRunFile then
		firstRunFile:close()
		os.remove("first.run")
		-- Fresh installation. Upstream bootstraps here by downloading the
		-- latest release; a fork must not, or it would immediately overwrite
		-- itself with the unlocalized build.
		ConClear()
		ConPrintf("First run: keeping the bundled i18n build.\n")
	end
	local xml = require("xml")
	local localManXML = xml.LoadXMLFile("manifest.xml") or xml.LoadXMLFile("../manifest.xml")
	if localManXML and localManXML[1].elem == "PoBVersion" then
		for _, node in ipairs(localManXML[1]) do
			if type(node) == "table" then
				if node.elem == "Version" then
					self.versionNumber = node.attrib.number
					self.versionBranch = node.attrib.branch
					self.versionPlatform = node.attrib.platform
				end
			end
		end
	end
	if localManXML and not self.versionBranch and not self.versionPlatform then
		-- Looks like a remote manifest, so we're probably running from a repository
		-- Enable dev mode to disable updates and set user path to be the script path
		self.devMode = true
	end
	local installedFile = io.open("installed.cfg", "r")
	if installedFile then
		self.installedMode = true
		installedFile:close()
	end
	RenderInit("DPI_AWARE")

	-- Localization. Hooks the engine's text functions, so it has to be in place
	-- before any module draws; the dictionary is optional and a build without
	-- one is byte-identical to upstream.
	POB_I18N = LoadModule("Modules/I18n")
	POB_I18N.Load(find_i18n_dir(), i18n_locale())
	POB_I18N.Install()

	ConPrintf("Loading main script...")
	local errMsg
	errMsg, self.main = PLoadModule("Modules/Main")
	if errMsg then
		self:ShowErrMsg("Error loading main script: %s", errMsg)
	elseif not self.main then
		self:ShowErrMsg("Error loading main script: no object returned")
	elseif self.main.Init then
		errMsg = PCall(self.main.Init, self.main)
		if errMsg then
			self:ShowErrMsg("In 'Init': %s", errMsg)
		end
	end

	if not self.updatesDisabled and not firstRunFile then
		-- Run a background update check if updates are enabled
		self:CheckForUpdate(true)
	end
end

function launch:CanExit()
	if self.main and self.main.CanExit and not self.promptMsg then
		local errMsg, ret = PCall(self.main.CanExit, self.main)
		if errMsg then
			self:ShowErrMsg("In 'CanExit': %s", errMsg)
			return false
		else
			return ret
		end
	end
	return true
end

function launch:OnExit()
	if self.main and self.main.Shutdown then
		PCall(self.main.Shutdown, self.main)
	end
end

function launch:OnFrame()
	if self.main then
		if self.main.OnFrame then
			local errMsg = PCall(self.main.OnFrame, self.main)
			if errMsg then
				-- Send user to build list menu if a build crashes on initial load
				if self.main.modes.BUILD.outputRevision == 1 and self.main.modes.BUILD.buildFlag and not self.devMode then
					main:SetMode("LIST")
				end
				self:ShowErrMsg("In 'OnFrame': %s", errMsg)
			end
		end
	end
	self.devModeAlt = self.devMode and IsKeyDown("ALT")
	SetDrawLayer(1000)
	SetViewport()
	if self.promptMsg then
		local r, g, b = unpack(self.promptCol)
		self:DrawPopup(r, g, b, "^0%s", self.promptMsg)
	end
	if self.doRestart then
		local screenW, screenH = GetVirtualScreenSize()
		SetDrawColor(0, 0, 0, 0.75)
		DrawImage(nil, 0, 0, screenW, screenH)
		SetDrawColor(1, 1, 1)
		DrawString(0, screenH/2, "CENTER", 24, "FIXED", self.doRestart)
		Restart()
	end
	if not self.updatesDisabled and (GetTime() - self.lastUpdateCheck) > 1000*60*60*12 then
		-- Do an update check every 12 hours if the user keeps the program open
		self:CheckForUpdate(true)
	end
end

function launch:OnKeyDown(key, doubleClick)
	if key == "F5" and self.devMode then
		self.doRestart = "Restarting..."
	elseif key == "F6" and self.devMode then
		local before = collectgarbage("count")
		collectgarbage("collect")
		ConPrintf("%dkB => %dkB", before, collectgarbage("count"))
	elseif key == "PAUSE" and self.devMode and profiler then
		if profiling then
			profiler.stop()
			profiler.report("profiler.log")
			profiling = false
		else
			profiler.start()
			profiling = true
		end
	elseif key == "u" and IsKeyDown("CTRL") then
		if not self.updatesDisabled then
			self:CheckForUpdate()
		end
	elseif key == "PRINTSCREEN" and IsKeyDown("CTRL") then
		TakeScreenshot()
	elseif self.promptMsg then
		self:RunPromptFunc(key)
	else
		if self.main and self.main.OnKeyDown then
			local errMsg = PCall(self.main.OnKeyDown, self.main, key, doubleClick)
			if errMsg then
				self:ShowErrMsg("In 'OnKeyDown': %s", errMsg)
			end
		end
	end
end

function launch:OnKeyUp(key)
	if not self.promptMsg then
		if self.main and self.main.OnKeyUp then
			local errMsg = PCall(self.main.OnKeyUp, self.main, key)
			if errMsg then
				self:ShowErrMsg("In 'OnKeyUp': %s", errMsg)
			end
		end
	end
end

function launch:OnChar(key)
	if self.promptMsg then
		self:RunPromptFunc(key)
	else
		if self.main and self.main.OnChar then
			local errMsg = PCall(self.main.OnChar, self.main, key)
			if errMsg then
				self:ShowErrMsg("In 'OnChar': %s", errMsg)
			end
		end
	end
end

function launch:OnSubCall(func, ...)
	if func == "UpdateProgress" then
		self.updateProgress = string.format(...)
	end
	if _G[func] then
		return _G[func](...)
	end
end

function launch:OnSubError(id, errMsg)
	if self.subScripts[id].type == "UPDATE" then
		self:ShowErrMsg("In update thread: %s", errMsg)
		self.updateCheckRunning = false
	elseif self.subScripts[id].type == "DOWNLOAD" then
		local errMsg = PCall(self.subScripts[id].callback, nil, errMsg)
		if errMsg then
			self:ShowErrMsg("In download callback: %s", errMsg)
		end
	end
	self.subScripts[id] = nil
end

function launch:OnSubFinished(id, ...)
	if self.subScripts[id].type == "UPDATE" then
		self.updateAvailable, self.updateErrMsg = ...
		self.updateCheckRunning = false
		if self.updateCheckBackground and self.updateAvailable == "none" then
			self.updateAvailable = nil
		end
	elseif self.subScripts[id].type == "DOWNLOAD" then
		local errMsg = PCall(self.subScripts[id].callback, ...)
		if errMsg then
			self:ShowErrMsg("In download callback: %s", errMsg)
		end
	elseif self.subScripts[id].type == "CUSTOM" then
		if self.subScripts[id].callback then
			local errMsg = PCall(self.subScripts[id].callback, ...)
			if errMsg then
				self:ShowErrMsg("In subscript callback: %s", errMsg)
			end
		end
	end
	self.subScripts[id] = nil
end

function launch:RegisterSubScript(id, callback)
	if id then
		self.subScripts[id] = {
			type = "CUSTOM",
			callback = callback,
		}
	end
end

---Download the given page in the background, and calls the provided callback function when done:
---@param url string
---@param callback fun(response:table, errMsg:string) @ response = { header, body }
---@param params? table @ params = { header, body }
function launch:DownloadPage(url, callback, params)
	params = params or {}
	local script = [[
		local url, requestHeader, requestBody, connectionProtocol, proxyURL, noSSL = ...
		local responseHeader = ""
		local responseBody = ""
		ConPrintf("Downloading page at: %s", url)
		local curl = require("lcurl.safe")
		local easy = curl.easy()
		if requestHeader then
			local header = {}
			for s in requestHeader:gmatch("[^\r\n]+") do
    			table.insert(header, s)
			end
			easy:setopt(curl.OPT_HTTPHEADER, header)
		end
		easy:setopt_url(url)
		easy:setopt(curl.OPT_USERAGENT, "Path of Building/]]..self.versionNumber..[[")
		easy:setopt(curl.OPT_ACCEPT_ENCODING, "")
		easy:setopt(curl.OPT_FOLLOWLOCATION, 1)
		if requestBody then
			easy:setopt(curl.OPT_POST, true)
			easy:setopt(curl.OPT_POSTFIELDS, requestBody)
		end
		if connectionProtocol then
			easy:setopt(curl.OPT_IPRESOLVE, connectionProtocol)
		end
		if proxyURL then
			easy:setopt(curl.OPT_PROXY, proxyURL)
		end
		if noSSL then
			easy:setopt(curl.OPT_SSL_VERIFYPEER, 0)
			easy:setopt(curl.OPT_SSL_VERIFYHOST, 0)
		end
		easy:setopt_headerfunction(function(data)
			responseHeader = responseHeader .. data
			return true
		end)
		easy:setopt_writefunction(function(data)
			responseBody = responseBody .. data
			return true
		end)
		local _, error = easy:perform()
		local code = easy:getinfo(curl.INFO_RESPONSE_CODE)
		easy:close()
		local errMsg
		if error then
			errMsg = error:msg()
		elseif code ~= 200 then
			errMsg = "Response code: "..code
		elseif #responseBody == 0 then
			errMsg = "No data returned"
		end
		ConPrintf("Download complete. Status: %s", errMsg or "OK")
		return responseBody, errMsg, responseHeader
	]]
	local id = LaunchSubScript(script, "", "ConPrintf", url, params.header, params.body, self.connectionProtocol, self.proxyURL, self.noSSL or false)
	if id then
		self.subScripts[id] = {
			type = "DOWNLOAD",
			callback = function(responseBody, errMsg, responseHeader)
				callback({header=responseHeader, body=responseBody}, errMsg)
			end
		}
	end
end
function launch:ApplyUpdate(mode)
	if self.updatesDisabled then
		return
	end
	if mode == "basic" then
		-- Need to revert to the basic environment to fully apply the update
		LoadModule("UpdateApply")("Update/opFile.txt")
		SpawnProcess(GetRuntimePath()..'/Update', 'UpdateApply.lua Update/opFileRuntime.txt')
		Exit()
	elseif mode == "normal" then
		-- Update can be applied while normal environment is running
		LoadModule("UpdateApply")("Update/opFile.txt")
		Restart()
		self.doRestart = "Updating..."
	end
end

function launch:CheckForUpdate(inBackground)
	if self.updatesDisabled then
		-- Fork build: the upstream manifest would replace every localized file.
		return
	end
	if self.updateCheckRunning then
		return
	end
	self.updateCheckBackground = inBackground
	self.updateMsg = "Initialising..."
	self.updateProgress = "Checking..."
	self.lastUpdateCheck = GetTime()
	local update = io.open("UpdateCheck.lua", "r")
	local id = LaunchSubScript(update:read("*a"), "GetScriptPath,GetRuntimePath,GetWorkDir,MakeDir", "ConPrintf,UpdateProgress", self.connectionProtocol, self.proxyURL, self.noSSL or false)
	if id then
		self.subScripts[id] = {
			type = "UPDATE"
		}
		self.updateCheckRunning = true
	end
	update:close()
end

function launch:ShowPrompt(r, g, b, str, func)
	self.promptMsg = str
	self.promptCol = {r, g, b}
	self.promptFunc = func or function(key)
		if key == "RETURN" or key == "ESCAPE" then
			return true
		elseif key == "F4" then
			if self.main then
				self.main.popups = { }
				self.main.inputEvents = { }
				self.main:SetMode("LIST")
			end
			return true
		elseif key == "c" and IsKeyDown("CTRL") then
			local cleanStr = str:gsub("%^%d", "")
			Copy(cleanStr)
		elseif key == "F5" then
			self.doRestart = "Restarting..."
			return true
		end
	end
end

function launch:ShowErrMsg(fmt, ...)
	if not self.promptMsg then
		local version = self.versionNumber and 
			"^8v"..self.versionNumber..(self.versionBranch and " "..self.versionBranch or "")
			or ""
		self:ShowPrompt(1, 0, 0, "^1Error:\n\n^0"..string.format(fmt, ...).."\n"..version.."\n^0Press Enter/Escape to dismiss, F4 to return to build selection, or F5 to restart the application.\nPress CTRL + C to copy error text.")
	end
end

function launch:RunPromptFunc(key)
	local curMsg = self.promptMsg
	local errMsg, ret = PCall(self.promptFunc, key)
	if errMsg then
		self:ShowErrMsg("In prompt func: %s", errMsg)
	elseif ret and self.promptMsg == curMsg then
		self.promptMsg = nil
	end
end

function launch:DrawPopup(r, g, b, fmt, ...)
	local screenW, screenH = GetVirtualScreenSize()
	SetDrawColor(0, 0, 0, 0.5)
	DrawImage(nil, 0, 0, screenW, screenH)
	local txt = string.format(fmt, ...)
	local w = DrawStringWidth(20, "VAR", txt) + 20
	local h = (#txt:gsub("[^\n]","") + 2) * 20
	local ox = (screenW - w) / 2
	local oy = (screenH - h) / 2
	SetDrawColor(1, 1, 1)
	DrawImage(nil, ox, oy, w, h)
	SetDrawColor(r, g, b)
	DrawImage(nil, ox + 2, oy + 2, w - 4, h - 4)
	SetDrawColor(1, 1, 1)
	DrawImage(nil, ox + 4, oy + 4, w - 8, h - 8)
	DrawString(0, oy + 10, "CENTER", 20, "VAR", txt)
end
