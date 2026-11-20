-- Path of Building
--
-- Module: I18n
-- Runtime translation of the strings POB draws.
--
-- POB has no localization layer: every label is an English literal passed to
-- DrawString. Rather than rewriting ~4000 call sites, this wraps the three
-- engine text functions and consults a dictionary on the way through.
--
-- The dictionary lives outside the repository (Data/<game>/<locale>/) so it can
-- be updated without touching code, and is keyed by the exact English string
-- POB draws -- punctuation, spacing and newlines included. A key that is
-- missing simply draws English, which is the intended failure mode: a wrong
-- translation is worse than an untranslated line.
--
-- Nothing here writes to the POB folder; a build without a dictionary behaves
-- exactly as upstream does.

local i18n = { }

-- Set to true by hand when tracing how a pasted item is reverse-translated.
i18n.debugItem = false

local t_insert = table.insert
local ipairs = ipairs
local pairs = pairs

-- Colour codes are part of the drawn string, not the key: "^7Fire" is drawn
-- as the escape plus "Fire". Split them off, translate the payload, put the
-- same codes back in the same places.
local function splitEscapes(s)
	-- parts[i] is preceded by codes[i] (nil when there is no code before it).
	local parts = { "" }
	local codes = { }
	local pos = 1
	local n = #s
	while pos <= n do
		-- "%^" is the literal caret; a bare "^" here would be a pattern anchor.
		local a, b = s:find("^%^x%x%x%x%x%x%x", pos)
		if not a then a, b = s:find("^%^%d", pos) end
		if a then
			codes[#parts] = s:sub(a, b)
			parts[#parts + 1] = ""
			pos = b + 1
		elseif s:sub(pos, pos) == "^" then
			-- A caret that starts no valid code is ordinary text. Consume it so
			-- the loop always advances (an unconsumed caret is an endless loop).
			parts[#parts] = parts[#parts] .. "^"
			pos = pos + 1
		else
			local nxt = s:find("%^", pos)
			local stop = (nxt or (n + 1)) - 1
			parts[#parts] = parts[#parts] .. s:sub(pos, stop)
			pos = stop + 1
		end
	end
	return parts, codes
end

-- "Grants 15% increased Life" against the key "Grants {0}% increased Life".
-- Returns the list of substrings the placeholders matched, or nil.
--
-- Built as a Lua pattern with captures, so the scan is one pass and cannot
-- backtrack into catastrophic territory: every literal segment is escaped and
-- the only wildcard is ".-", which never spans a newline.
-- A key compiles to one pattern, and the same key is retried against many
-- drawn strings while a bucket is scanned, so compiling once here is the
-- difference between ~0.2 ms and ~0.02 ms per candidate.
local compiledPatterns = { }

local function compileKey(key)
	local pieces = { }
	local last = 1
	while true do
		local a, b = key:find("{", last, true)
		if not a then break end
		local c, d = key:find("}", b, true)
		if not c then break end
		pieces[#pieces + 1] = { literal = key:sub(last, a - 1) }
		-- The slot may carry a format spec ("{0:+d}"); the digits are the key,
		-- the spec only describes how POB already formatted the value, so the
		-- captured text is substituted verbatim.
		pieces[#pieces + 1] = { slot = key:sub(b + 1, c - 1):match("^(%d+)") }
		last = c + 1
	end
	pieces[#pieces + 1] = { literal = key:sub(last) }

	local pattern = "^"
	local slots = { }
	for _, p in ipairs(pieces) do
		if p.literal then
			pattern = pattern .. (p.literal:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
		else
			pattern = pattern .. "(.-)"
			slots[#slots + 1] = p.slot
		end
	end
	return { pattern = pattern .. "$", slots = slots }
end

local function matchPlaceholders(key, text)
	local c = compiledPatterns[key]
	if not c then
		c = compileKey(key)
		compiledPatterns[key] = c
	end
	local pattern, slots = c.pattern, c.slots

	local caps = { text:match(pattern) }
	-- A failed match yields no captures, which is indistinguishable from a
	-- template whose slots all failed to parse. Without this check such a key
	-- "matches" any text with the same numeric-token count and prefix, and
	-- substitutes its whole translation -- that is how a resist breakdown line
	-- turned into a league-transfer string. Every indexed key has at least one
	-- slot, so a real match always produces a capture (possibly empty).
	if caps[1] == nil or #caps ~= #slots then return nil end
	local values = { }
	for i, slot in ipairs(slots) do
		values[slot] = caps[i]
	end
	return values
end

-- Substitute a template's placeholders with the captured values.
local function fillPlaceholders(template, values)
	return (template:gsub("{(%d+)[^}]*}", function(slot)
		local v = values[slot]
		if v == nil then return "{" .. slot .. "}" end
		return v
	end))
end

-- The game's own strings carry display markup POB knows nothing about, and it
-- draws whatever it is handed, so "<rgb(155,55,55)>" would appear literally.
-- Keep the colour the source asked for by turning it into POB's ^xRRGGBB code,
-- then drop every other tag.
local function sanitizeMarkup(s)
	if not s:find("<", 1, true) then return s end
	s = s:gsub("<rgb%(%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)%s*%)>", function(r, g, b)
		return string.format("^x%02X%02X%02X", r, g, b)
	end)
	return (s:gsub("</?[%a:][^>]*>", ""))
end

-- ==== reverse lookup ========================================================
--
-- Items copied from the game in a Chinese client are Chinese, but every item
-- parser downstream matches English keywords ("Rarity:", "Item Level:") and
-- English stat lines. The dictionary already maps those to Chinese, so the
-- same data read backwards turns a Chinese item back into the English text
-- POB knows how to parse.

local function buildReverseIndex()
	i18n.revExact = { }
	i18n.revTemplates = { }
	for k, v in pairs(i18n.entries) do
		if k ~= v then
			local slots = 0
			for _ in v:gmatch("{%d+[^}]*}") do slots = slots + 1 end
			if slots > 0 then
				local bucket = i18n.revTemplates[slots]
				if not bucket then bucket = { } i18n.revTemplates[slots] = bucket end
				local lead = v:match("^([^{]*)")
				local first = (#lead >= 2 and lead:sub(1, 2)) or v:match("^{%d+[^}]*}%s*(..)")
				if first and #first > 0 then
					bucket[first] = bucket[first] or { }
					t_insert(bucket[first], { zh = v, en = k })
				end
			else
				-- Several English keys can share one translation ("智慧" is both
				-- "Int" and "Intelligence"). Keep the shortest: it is the plain
				-- word rather than a longer composite that happens to include it.
				local cur = i18n.revExact[v]
				if cur == nil or #k < #cur then
					i18n.revExact[v] = k
				end
			end
		end
	end
	-- Within one bucket, try the longest English key first: "+23 智慧" must
	-- resolve to "+23 to Intelligence", not the abbreviation "+23 Int".
	local function byLengthDesc(a, b)
		return #a.en > #b.en
	end
	for _, bucket in pairs(i18n.revTemplates) do
		for _, list in pairs(bucket) do
			table.sort(list, byLengthDesc)
		end
	end
end

-- The dictionary keeps the game's "[English|Chinese]" term markup in some
-- values. Reading one back must yield just the term, or the parser sees
-- "+23 to [Intelligence|Intelligence]".
local function stripTermMarkup(s)
	if not s:find("[", 1, true) then return s end
	s = s:gsub("%[([^%|%]]+)%|([^%|%]]+)%]", "%2")
	return (s:gsub("%[([^%|%]]+)%]", "%1"))
end

-- Translate one Chinese line back to English, or nil when nothing matches.
function i18n.ReverseTranslate(zhText)
	if not i18n.loaded or type(zhText) ~= "string" or #zhText == 0 then return nil end
	local direct = i18n.revExact[zhText]
	if direct then return stripTermMarkup(direct) end
	if not zhText:find("%d") then return nil end
	local slots = select(2, zhText:gsub("%-?%d+%.?%d*", ""))
	local bucket = i18n.revTemplates[slots]
	if not bucket then return nil end
	local head = zhText:sub(1, 2)
	local afterNumber = zhText:match("^[%+%-]?%d+%.?%d*%s*(..)")
	for _, which in ipairs(afterNumber and { head, afterNumber } or { head }) do
		local list = bucket[which]
		if list then
			for _, tpl in ipairs(list) do
				local values = matchPlaceholders(tpl.zh, zhText)
				if values then
					local en = fillPlaceholders(tpl.en, values)
					-- A slot present in the English key but absent from the
					-- Chinese one survives substitution; that is not a match.
					if not en:find("{", 1, true) then
						return stripTermMarkup(en)
					end
				end
			end
		end
	end
	return nil
end

-- Keywords the item parser matches literally. The Chinese client renders the
-- rarity line with a space between every character ("稀 有 度: 稀有"), so the
-- caller matches against a space-stripped copy.
local ITEM_RARITY = {
	["普通"] = "NORMAL",
	["魔法"] = "MAGIC",
	["稀有"] = "RARE",
	["传奇"] = "UNIQUE",
	["遗物"] = "RELIC",
}

local ITEM_SPEC = {
	["物品类别"] = "Item Class",
	["物品等级"] = "Item Level",
	["需求"] = "Requirements",
	["等级"] = "Level",
	["力量"] = "Strength",
	["敏捷"] = "Dexterity",
	["智慧"] = "Intelligence",
	["品质"] = "Quality",
	["护甲"] = "Armour",
	["闪避值"] = "Evasion Rating",
	["能量护盾"] = "Energy Shield",
	["攻击速度"] = "Attacks per Second",
	["暴击几率"] = "Critical Strike Chance",
	["物理伤害"] = "Physical Damage",
	["元素伤害"] = "Elemental Damage",
	["每秒攻击次数"] = "Attacks per Second",
}

local ITEM_FLAG = {
	["已腐化"] = "Corrupted",
	["已复制"] = "Mirrored",
	["已污染"] = "Corrupted",
}

local ITEM_CLASS = {
	["戒指"] = "Ring",
	["护身符"] = "Amulet",
	["腰带"] = "Belt",
	["头盔"] = "Helmet",
	["胸甲"] = "Body Armour",
	["手套"] = "Gloves",
	["鞋子"] = "Boots",
	["盾"] = "Shield",
	["箭袋"] = "Quiver",
	["药剂"] = "Flask",
	["珠宝"] = "Jewel",
	["法杖"] = "Staff",
	["长杖"] = "Staff",
	["弓"] = "Bow",
	["爪"] = "Claw",
	["匕首"] = "Dagger",
	["单手剑"] = "One Handed Sword",
	["双手剑"] = "Two Handed Sword",
	["单手斧"] = "One Handed Axe",
	["双手斧"] = "Two Handed Axe",
	["单手锤"] = "One Handed Mace",
	["双手锤"] = "Two Handed Mace",
	["权杖"] = "Sceptre",
	["战杖"] = "Warstaff",
	["鱼竿"] = "Fishing Rod",
	["地图"] = "Map",
}

-- Turn a Chinese item into the English text the item parser expects. Lines
-- that map to nothing (rare item names, flavour text) are left untouched, so
-- they keep displaying in Chinese.
function i18n.NormaliseItemText(raw)
	if not i18n.loaded or type(raw) ~= "string" or not raw:find("[\128-\255]") then
		return raw
	end
	local out = { }
	local itemClassLine
	local sawRarity = false
	local function emit(text)
		out[#out + 1] = text
	end
	for line in (raw .. "\n"):gmatch("(.-)\n") do
		local squashed = line:gsub("%s+", "")
		local replaced
		local EnglishRarity = squashed:match("^Rarity:(%a+)$")
		local rarity = squashed:match("^稀有度:(.+)$")
		if EnglishRarity then
			-- Already-English rarity (the item editor prepends one). Remember it
			-- so a Chinese rarity line further down is dropped instead of
			-- being read as the item name.
			sawRarity = true
			replaced = line
		elseif rarity and ITEM_RARITY[rarity] then
			-- A caller may have prepended its own "Rarity: X" already; keep the
			-- first one only, or the second ends up read as the item name.
			if not sawRarity then
				sawRarity = true
				replaced = "Rarity: " .. ITEM_RARITY[rarity]
			else
				replaced = "\0drop"
			end
		else
			local name, value = squashed:match("^([^:]+):(.*)$")
			if name == "物品类别" then
				-- The parser only expects Item Class first; a Chinese client puts
				-- it there too, but whoever calls us may have inserted a rarity
				-- line above it. Emit it out of band and place it first.
				itemClassLine = "Item Class: " .. (ITEM_CLASS[value] or value)
				replaced = "\0drop"
			else
				local spec = name and ITEM_SPEC[name]
				if spec then
					-- The value of a spec line is a plain enum ("戒指"), not a
					-- stat line, so look it up directly before trying templates.
					local mapped = value ~= "" and (i18n.revExact[value] or i18n.ReverseTranslate(value)) or nil
					replaced = value ~= "" and (spec .. ": " .. (mapped or value)) or (spec .. ":")
				elseif ITEM_FLAG[squashed] then
					replaced = ITEM_FLAG[squashed]
				elseif squashed == "稀有度" or squashed == "物品类别" then
					replaced = "\0drop"
				end
			end
		end
		if replaced == "\0drop" then
			-- dropped, see above
		elseif replaced then
			emit(replaced)
		else
			emit(i18n.ReverseTranslate(line) or line)
		end
	end
	if itemClassLine then
		t_insert(out, 1, itemClassLine)
	end
	local result = table.concat(out, "\n")
	if i18n.debugItem then
		ConPrintf("[i18n-item] IN : %s", (raw:gsub("\n", " | ")))
		ConPrintf("[i18n-item] OUT: %s", (result:gsub("\n", " | ")))
	end
	return result
end

-- ==== locale discovery ======================================================
--
-- i18n/ holds one directory per locale plus a manifest naming them. The
-- manifest is what ships in the repository; the dictionary payloads are
-- distributed separately, so a locale listed there may be absent on disk and
-- must not be offered.

local function fileExists(path)
	local f = io.open(path, "rb")
	if f then f:close() return true end
	return false
end

local function readManifest(baseDir)
	if not baseDir then return nil end
	local f = io.open(baseDir .. "/manifest.json", "rb")
	if not f then return nil end
	local text = f:read("*a")
	f:close()
	local dkjson = require("dkjson")
	local ok, doc = pcall(dkjson.decode, text, 1, nil)
	if ok and type(doc) == "table" then
		return doc
	end
	ConPrintf("[i18n] could not parse %s/manifest.json", baseDir)
	return nil
end

-- Locales the user can pick, in display order: the built-in default first,
-- then everything the manifest names that is actually present on disk. The
-- engine offers no directory enumeration, so the manifest is authoritative —
-- add an entry there and drop the folder in to add a language.
function i18n.AvailableLocales()
	local list = { { id = "en", name = "Default", nativeName = "Default (English)" } }
	local seen = { en = true }
	local manifest = readManifest(i18n.baseDir)
	if manifest and type(manifest.locales) == "table" then
		for _, entry in ipairs(manifest.locales) do
			if type(entry) == "table" and type(entry.id) == "string" and not seen[entry.id]
				and fileExists(i18n.baseDir .. "/" .. entry.id .. "/meta.json") then
				seen[entry.id] = true
				t_insert(list, {
					id = entry.id,
					name = entry.name or entry.id,
					nativeName = entry.nativeName or entry.name or entry.id,
				})
			end
		end
	end
	return list
end

function i18n.LocaleExists(locale)
	return locale == "en" or (i18n.baseDir ~= nil and fileExists(i18n.baseDir .. "/" .. locale .. "/meta.json"))
end

-- The locale to use when no preference has been saved.
function i18n.DefaultLocale()
	local manifest = readManifest(i18n.baseDir)
	if manifest and type(manifest.defaultLocale) == "string" and i18n.LocaleExists(manifest.defaultLocale) then
		return manifest.defaultLocale
	end
	return "en"
end

-- Reload with another locale. Safe to call while running: the drawing hooks
-- stay installed and read the current tables on every string.
function i18n.SetLocale(locale)
	if not locale or locale == i18n.lang then
		return
	end
	i18n.Load(i18n.baseDir, locale)
end

-- ==== remote updates ========================================================
--
-- The dictionaries live in their own repository. A configured base URL is read
-- as: <base>/manifest.json plus <base>/<locale>/<file>. Each file in the
-- manifest carries a SHA1, so an update downloads only what changed — the game
-- data dictionaries are 12 MB and most releases touch one or two files.

-- Accept the URL people actually have in their clipboard (the repo page) as
-- well as a raw content base. Anything else is used verbatim, so a self-hosted
-- mirror works with no special casing.
function i18n.NormaliseRepoUrl(url)
	url = (url or ""):gsub("%s+$", ""):gsub("/+$", "")
	if url == "" then return nil end
	local owner, repo = url:match("^https?://github%.com/([^/]+)/([^/#?]+)")
	if owner then
		repo = repo:gsub("%.git$", "")
		return "https://raw.githubusercontent.com/" .. owner .. "/" .. repo .. "/HEAD"
	end
	return url
end

local function sha1Of(path)
	local f = io.open(path, "rb")
	if not f then return nil end
	local data = f:read("*a")
	f:close()
	return require("sha1")(data)
end

-- Fill "{0}"-style slots at runtime. This is the same convention the
-- dictionary uses for its template keys, so the produced string and the key
-- line up; string.format is not usable here because it speaks "%s".
function i18n.Fill(template, ...)
	local args = { ... }
	return (template:gsub("{(%d+)}", function(slot)
		return tostring(args[tonumber(slot) + 1])
	end))
end

local function writeFileAtomic(path, data)
	local tmp = path .. ".tmp"
	local f = io.open(tmp, "wb")
	if not f then return nil, "cannot write " .. tmp end
	f:write(data)
	f:close()
	-- On Windows, rename does not replace an existing file, which is exactly
	-- the case that matters here: every update overwrites a file that is
	-- already installed.
	local ok, err = os.rename(tmp, path)
	if not ok then
		os.remove(path)
		ok, err = os.rename(tmp, path)
	end
	if not ok then
		os.remove(tmp)
		return nil, err or ("cannot replace " .. path)
	end
	return true
end

-- Locales that a sync should bring up to date: the ones already installed, or
-- — on a fresh install — the repository's default, so pointing a bare client at
-- the repo is enough to get it working.
local function syncTargets(remote)
	local targets = { }
	local present = { }
	for _, locale in ipairs(remote.locales or { }) do
		if type(locale) == "table" and type(locale.id) == "string"
			and fileExists(i18n.baseDir .. "/" .. locale.id .. "/meta.json") then
			present[locale.id] = true
			t_insert(targets, locale)
		end
	end
	if #targets == 0 then
		local wanted = remote.defaultLocale
		for _, locale in ipairs(remote.locales or { }) do
			if type(locale) == "table" and locale.id == wanted and type(locale.files) == "table" then
				t_insert(targets, locale)
				break
			end
		end
	end
	return targets
end

-- Fetch the manifest, then each file whose SHA1 differs. `onDone` is called
-- once with { updated = <bool>, downloaded = <n>, total = <n>, error = <str|nil>,
-- progress = <str> }. Progress updates arrive through onProgress when given.
function i18n.CheckForUpdates(onProgress, onDone)
	onDone = onDone or function() end
	onProgress = onProgress or function() end
	local base = i18n.NormaliseRepoUrl(i18n.repoUrl)
	if not base then
		onDone({ error = "No translation repository is configured." })
		return
	end
	if not i18n.baseDir then
		onDone({ error = "No i18n directory is installed next to the application." })
		return
	end
	local function fail(msg)
		onDone({ error = msg })
	end
	onProgress("Checking for updates...")
	launch:DownloadPage(base .. "/manifest.json", function(response, errMsg)
		if errMsg then
			fail(i18n.Fill("Could not reach the repository ({0})", errMsg))
			return
		end
		local dkjson = require("dkjson")
		local ok, remote = pcall(dkjson.decode, response.body, 1, nil)
		if not ok or type(remote) ~= "table" or type(remote.locales) ~= "table" then
			fail("The repository manifest is not valid JSON.")
			return
		end
		local queue = { }
		local unchanged = 0
		for _, locale in ipairs(syncTargets(remote)) do
			if type(locale.files) == "table" then
				for name, sha in pairs(locale.files) do
					if type(name) == "string" and type(sha) == "string" and not name:find("[/\\]") then
						local path = i18n.baseDir .. "/" .. locale.id .. "/" .. name
						if sha1Of(path) ~= sha then
							t_insert(queue, { locale = locale.id, name = name, sha = sha, path = path })
						else
							unchanged = unchanged + 1
						end
					end
				end
			end
		end
		if #queue == 0 then
			onDone({ updated = false, unchanged = unchanged, total = unchanged })
			return
		end

		-- One file at a time: the download helper runs each request in its own
		-- subscript, and firing dozens at once would spawn that many Lua states.
		local index = 0
		local downloaded = 0
		local function nextFile()
			index = index + 1
			local item = queue[index]
			if not item then
				-- Record what is now installed so the locale list and the next
				-- diff both agree with the files on disk.
				local f = io.open(i18n.baseDir .. "/manifest.json", "wb")
				if f then
					f:write(response.body)
					f:close()
				end
				local current = i18n.lang
				i18n.Load(i18n.baseDir, current)
				onProgress("")
				onDone({ updated = true, downloaded = downloaded, total = #queue + unchanged })
				return
			end
			onProgress(i18n.Fill("Downloading {0} ({1}/{2})...", item.name, index, #queue))
			MakeDir(i18n.baseDir .. "/" .. item.locale)
			launch:DownloadPage(base .. "/" .. item.locale .. "/" .. item.name, function(fileResponse, fileErr)
				if fileErr then
					fail(i18n.Fill("Could not download {0} ({1})", item.name, fileErr))
					return
				end
				local written, writeErr = writeFileAtomic(item.path, fileResponse.body)
				if not written then
					fail(i18n.Fill("Could not save {0} ({1})", item.name, writeErr))
					return
				end
				downloaded = downloaded + 1
				nextFile()
			end)
		end
		nextFile()
	end)
end

function i18n.Load(dataDir, locale)
	i18n.baseDir = dataDir
	i18n.entries = { }
	-- Lowercased view of the keys. Every search predicate lowercases the
	-- haystack before matching (searchName:lower(), label:lower()), so without
	-- this the lookup always misses on capitalised names.
	i18n.lower = { }
	i18n.templates = { }   -- placeholder keys, grouped by slot count
	i18n.lang = locale
	i18n.loaded = false

	if locale == "en" then
		ConPrintf("[i18n] locale is 'en': drawing the original text")
		return
	end
	if not dataDir then
		ConPrintf("[i18n] no dictionary directory found: drawing the original text")
		return
	end

	local metaPath = dataDir .. "/" .. locale .. "/meta.json"
	local mf = io.open(metaPath, "rb")
	if not mf then
		ConPrintf("[i18n] no dictionary at %s", metaPath)
		return
	end
	local metaText = mf:read("*a")
	mf:close()

	local dkjson = require("dkjson")
	local ok, meta = pcall(dkjson.decode, metaText, 1, nil)
	if not ok or type(meta) ~= "table" or type(meta.load_order) ~= "table" then
		ConPrintf("[i18n] could not parse %s", metaPath)
		return
	end

	-- Index one template key under the discriminator the lookup can derive
	-- from a drawn string. Keys are bucketed by (slot count, discriminator);
	-- without an entry here a key is unreachable no matter how correct its
	-- translation is.
	local function indexTemplate(key)
		local lead = key:match("^([^{]*)")
		if not lead or not key:find("{", 1, true) then return end
		local slots = 0
		for _ in key:gmatch("{%d+[^}]*}") do slots = slots + 1 end
		if slots == 0 then return end

		-- The discriminator: two characters the lookup can derive from a drawn
		-- string, either its opening literal or the one after its first value.
		local first
		if #lead >= 2 then
			first = lead:sub(1, 2)
		else
			-- The literal prefix is too short to key on: "{0} points to node"
			-- has none, and "+{0}% to Item Rarity" has only the sign. Use the
			-- literal that follows the first placeholder instead — the lookup
			-- derives that same literal from the number it consumed.
			first = key:match("^[^{]-{%d+[^}]*}%s*(..)")
				-- "{0}s" leaves a single character after the number.
				or key:match("^[^{]-{%d+[^}]*}%s*(.)$")
		end
		if not first or #first == 0 then return end

		-- Each placeholder is drawn as a value, so a drawn string carries one
		-- number per placeholder PLUS whatever numbers the key spells out
		-- itself ("... per 5% Map Quality"). Index under every count the drawn
		-- form can have or the bucket lookup misses the key entirely.
		-- matchPlaceholders still verifies the literals, so a wider index
		-- cannot produce a wrong match.
		local rest = key:gsub("{%d+[^}]*}", "")
		local literalNumbers = 0
		for _ in rest:gmatch("%d+%.?%d*") do literalNumbers = literalNumbers + 1 end

		-- Second discriminator: the four characters after the first
		-- placeholder. The first bucket still holds ~140 keys on average, and
		-- a miss pays for a full pattern match on every one of them (~31 ms a
		-- call). This splits that bucket by the text that follows the value.
		local _, phEnd = key:find("{%d+[^}]*}")
		local second = phEnd and key:sub(phEnd + 1, phEnd + 4) or nil
		if second == "" then second = nil end

		for n = slots, slots + literalNumbers do
			local bucket = i18n.templates[n]
			if not bucket then bucket = { } i18n.templates[n] = bucket end
			local group = bucket[first]
			if not group then group = { all = { }, free = { }, sub = { } } bucket[first] = group end
			t_insert(group.all, key)
			-- The two lists are disjoint: a key is in `sub` when its tail can
			-- be derived from the drawn string, and in `free` when it cannot.
			-- Scanning both on a miss would cost more than the single list it
			-- replaces, so a key must never appear in both.
			if second then
				local sub = group.sub[second]
				if not sub then sub = { } group.sub[second] = sub end
				t_insert(sub, key)
			else
				t_insert(group.free, key)
			end
		end
	end

	local total = 0
	for _, file in ipairs(meta.load_order) do
		local path = dataDir .. "/" .. locale .. "/" .. file
		local f = io.open(path, "rb")
		if f then
			local text = f:read("*a")
			f:close()
			local dok, doc = pcall(dkjson.decode, text, 1, nil)
			if dok and type(doc) == "table" and type(doc.entries) == "table" then
				for k, v in pairs(doc.entries) do
					if type(k) == "string" and type(v) == "string" and v ~= "" and v ~= k then
						-- Entries are stored JSON-escaped ("\\n"), and so is the
						-- string POB draws at runtime, so no unescaping is done.
						v = sanitizeMarkup(v)
						i18n.entries[k] = v
						-- Lua long-bracket literals ([=[...]=]) drop the newline
						-- after the opener but keep the one before the closer, so
						-- a key copied from source often carries padding the drawn
						-- string does not, or lacks padding it has. Register the
						-- trimmed form too; an exact key still wins.
						local trimmed = k:gsub("^[\r\n]+", ""):gsub("[\r\n]+$", "")
						if trimmed ~= k and i18n.entries[trimmed] == nil then
							i18n.entries[trimmed] = v
						end
						local low = k:lower()
						if i18n.lower[low] == nil then i18n.lower[low] = v end
						local lowTrimmed = trimmed:lower()
						if i18n.lower[lowTrimmed] == nil then i18n.lower[lowTrimmed] = v end
						indexTemplate(k)
						-- A key copied from a Lua long-bracket literal often
						-- carries padding the drawn string does not. The trimmed
						-- form is registered in `entries` above, so it has to be
						-- indexed too or it can only be found by exact match.
						if trimmed ~= k then indexTemplate(trimmed) end
						total = total + 1
					end
				end
			else
				ConPrintf("[i18n] skipped %s (bad JSON)", file)
			end
		end
	end
	i18n.loaded = total > 0
	if i18n.loaded then
		buildReverseIndex()
	end
	ConPrintf("[i18n] loaded %d entries (%s)", total, locale)
end

-- Exact lookup, plus the one-colon mismatch in both directions: POB appends
-- ":" to some labels and stores it in others ("Current build:" drawn, "Current
-- build" in the dictionary; the reverse for "Compare").
local function probeExact(text)
	local d = i18n.entries[text]
	if d then return d end
	-- Controls often reset the colour before drawing a label ("^7Strength:")
	-- so it inherits nothing from whatever was drawn last. The dictionary
	-- keys the label without that prefix, so look it up and put the prefix
	-- back on the way out.
	-- A colour code is "^x" plus six hex digits, or "^" plus one digit.
	-- Lua patterns have no alternation, so the runs are walked one at a time.
	local pos = 1
	while true do
		local a, b = text:find("^%^x%x%x%x%x%x%x", pos)
		if not a then a, b = text:find("^%^%d", pos) end
		if not a then break end
		pos = b + 1
	end
	local lead = pos > 1 and text:sub(1, pos - 1) or nil
	if lead then
		local body = text:sub(pos)
		local hit = i18n.entries[body]
		if hit then return lead .. hit end
		if body:sub(-1) == ":" then
			local bare = i18n.entries[body:sub(1, -2)]
			if bare then return lead .. bare .. ":" end
		else
			local plus = i18n.entries[body .. ":"]
			if plus then return lead .. plus end
		end
	end
	-- Multiline labels are drawn with whatever padding the literal carried.
	-- Retry without it before giving up on the entry.
	local trimmed = text:gsub("^[\r\n]+", ""):gsub("[\r\n]+$", "")
	if trimmed ~= text then
		d = i18n.entries[trimmed]
		if d then return d end
	end
	if text:sub(-1) == ":" then
		-- Label drawn with a trailing colon ("Strength:"); the dictionary key
		-- does not carry it, so restore it on the translation.
		local bare = i18n.entries[text:sub(1, -2)]
		return bare and (bare .. ":")
	end
	return i18n.entries[text .. ":"]
end

-- Translate one drawn string. Returns the input unchanged when there is no
-- exact hit, which is the common case for runtime-built text.
function i18n.Translate(text)
	if not i18n.loaded or type(text) ~= "string" or #text == 0 then return text end

	local direct = probeExact(text)
	if direct then return direct end

	-- Placeholder templates ("Grants {0}% increased Life"). Templates are indexed
	-- by slot count and leading literal when the dictionary loads, so a lookup
	-- narrows to a handful of candidates instead of scanning every key — without
	-- that the per-frame cost is the whole template table and the UI stops.
	if text:find("%d") then
		local slots = select(2, text:gsub("%-?%d+%.?%d*", ""))
		local bucket = i18n.templates[slots]
		if bucket then
			-- Literal-prefix templates ("Grants {0}% ...") and
			-- leading-placeholder templates ("{0} points to node") live in
			-- different buckets.
			local candidates = { text:sub(1, 2) }
			-- A sign belongs to the number ("%+g" formats signed mods that
			-- way). Search anywhere rather than anchored: a drawn string can
			-- open with punctuation before its first value — "(15 unread ..."
			-- is keyed as "({0} unread ...".
			local afterNumber = text:match("[%+%-]?%d+%.?%d*%s*(..)")
			if afterNumber then
				candidates[#candidates + 1] = afterNumber
			else
				-- "{0}s" leaves a single character after the number.
				candidates[#candidates + 1] = text:match("[%+%-]?%d+%.?%d*%s*(.)$")
			end
			-- The four characters after a value, matching the second
			-- discriminator the keys were indexed under. Every number is
			-- tried: a key can spell out a literal number before its first
			-- placeholder ("With at least 40 Intelligence ... has {0}%"), and
			-- only the position of the real value yields the indexed tail.
			local tailKeys = { }
			local from = 1
			while true do
				local _, numEnd = text:find("[%+%-]?%d+%.?%d*", from)
				if not numEnd then break end
				tailKeys[#tailKeys + 1] = text:sub(numEnd + 1, numEnd + 4)
				from = numEnd + 1
			end

			for _, which in ipairs(candidates) do
				local group = bucket[which]
				if group then
					for _, tailKey in ipairs(tailKeys) do
						local sub = group.sub[tailKey]
						if sub then
							for _, key in ipairs(sub) do
								local values = matchPlaceholders(key, text)
								if values then
									return fillPlaceholders(i18n.entries[key], values)
								end
							end
						end
					end
					-- Keys with no derivable tail: nothing follows their first
					-- placeholder, so the drawn string cannot be narrowed either.
					for _, key in ipairs(group.free) do
						local values = matchPlaceholders(key, text)
						if values then
							return fillPlaceholders(i18n.entries[key], values)
						end
					end
					-- Last resort. A key's tail is derived from where its first
					-- placeholder sits; when the drawn string puts a number
					-- somewhere the key does not, the narrowing above picks the
					-- wrong slot and only a full scan finds the key. Only misses
					-- reach here, so the cost is paid where there is no answer
					-- to be had quickly.
					for _, key in ipairs(group.all) do
						local values = matchPlaceholders(key, text)
						if values then
							return fillPlaceholders(i18n.entries[key], values)
						end
					end
				end
			end
		end
	end

	-- Concatenated label + value: POB draws "Current build:  "..buildName as one
	-- string, so neither half matches on its own. Translate the label part and
	-- keep the value and separator untouched. Only lookups run on the head, never
	-- a recursive Translate, so this cannot loop.
	if #text <= 160 then
		local p = text:find("  ", 1, true)
		if p and p > 1 then
			local head = probeExact(text:sub(1, p - 1))
			if head then return head .. text:sub(p) end
		end
		-- "Label: value" -- the colon may carry a space after it or not, and the
		-- label may carry one before it or not. Translate the label and keep
		-- the separator and value as drawn.
		local q = text:find(":", 1, true)
		if q and q > 1 then
			local head = probeExact(text:sub(1, q - 1)) or probeExact(text:sub(1, q - 2))
			if head then return head .. text:sub(q) end
		end
	end
	return text
end

-- Translate a string that may carry colour escapes, keeping the escapes.
function i18n.TranslateColoured(text)
	if not i18n.loaded or type(text) ~= "string" then return text end
	local direct = probeExact(text)
	if direct then return direct end
	-- Fast path: most drawn strings are short labels with no escapes and no
	-- dictionary entry. Returning here keeps the per-frame cost to one table
	-- lookup plus one failed template probe.
	if not text:find("%^") then return i18n.Translate(text) end

	local parts, codes = splitEscapes(text)
	local changed = false
	for i = 1, #parts do
		if parts[i] ~= "" then
			local t = i18n.Translate(parts[i])
			if t ~= parts[i] then
				parts[i] = t
				changed = true
			end
		end
	end
	if not changed then return text end

	local out = { }
	for i = 1, #parts do
		if codes[i] then out[#out + 1] = codes[i] end
		out[#out + 1] = parts[i]
	end
	return table.concat(out)
end

-- ==== search ===============================================================

local function hasNonAscii(s)
	return s ~= nil and s:find("[\128-\255]") ~= nil
end

-- POB searches the English source because that is what it stores; the user
-- types what they see, which is the translation. Every one of the search
-- predicates funnels through string.matchOrPattern (13 call sites: config tab,
-- item DB, minion list, anoint popup, tree view, ...), so wrapping that one
-- function covers them all. The wrapper only fires for a non-ASCII query --
-- an English search must not pay for a table lookup per row.
--
-- Translating the haystack is safe with a Lua pattern: the pattern is parsed,
-- the haystack is data, so a translation containing "%" or "(" cannot break
-- the match.
function i18n.InstallSearch()
	if i18n.searchInstalled then return end
	local orig = string.matchOrPattern
	if type(orig) ~= "function" then
		ConPrintf("[i18n] matchOrPattern not available yet; search stays English-only")
		return
	end
	i18n.searchInstalled = true
	ConPrintf("[i18n] search hook installed")

	function string.matchOrPattern(self, pattern)
		if orig(self, pattern) then return true end
		if not i18n.loaded or not hasNonAscii(pattern) then return false end
		-- Callers lowercase the haystack before searching (searchName:lower()),
		-- so the lookup goes through the lowercased index rather than the keys.
		local zh = i18n.lower[self]
		if not zh then return false end
		return orig(zh, pattern)
	end
end

-- Some searches do not go through matchOrPattern: the calcs tab compares with
-- find(), and the gem picker builds its own pattern list. They call this so a
-- Chinese query behaves the same as everywhere else.
function i18n.SearchMatch(text, query)
	if not text or not query or query == "" then
		return false
	end
	if text:lower():find(query) then
		return true
	end
	if not i18n.loaded or not hasNonAscii(query) then
		return false
	end
	local zh = i18n.lower[text:lower()]
	-- Plain find: the query is user input, not a pattern.
	return zh ~= nil and zh:find(query, 1, true) ~= nil
end

-- Chinese name for an English one, or nil when the dictionary has no entry.
function i18n.TranslatedName(name)
	if not i18n.loaded or not name then
		return nil
	end
	return i18n.lower[name:lower()]
end

-- ==== engine hooks =========================================================
-- DrawString/DrawStringWidth/DrawStringCursorIndex are plain globals the engine
-- installs, and no POB module caches them in a local (checked), so replacing
-- them here reaches every call site.

function i18n.Install()
	if i18n.installed then return end
	i18n.installed = true

	local baseDraw = DrawString
	local baseWidth = DrawStringWidth
	local baseCursor = DrawStringCursorIndex

	DrawString = function(left, top, align, height, font, text)
		return baseDraw(left, top, align, height, font, i18n.TranslateColoured(text))
	end

	-- Width must be measured on the translated string, or every centred and
	-- right-aligned label is positioned as if it were still English.
	DrawStringWidth = function(height, font, text)
		return baseWidth(height, font, i18n.TranslateColoured(text))
	end

	-- The caret index is an index into the ORIGINAL string: EditControl stores
	-- self.buf in English and only translates at draw time, so the untranslated
	-- text is what the cursor has to line up with.
	DrawStringCursorIndex = function(height, font, text, cursorX, cursorY)
		return baseCursor(height, font, text, cursorX, cursorY)
	end
end

return i18n
