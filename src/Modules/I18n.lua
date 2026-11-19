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
local function matchPlaceholders(key, text)
	local pieces = { }
	local last = 1
	local idx = 0
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
		idx = idx + 1
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
	pattern = pattern .. "$"

	local caps = { text:match(pattern) }
	if #caps ~= #slots then return nil end
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

function i18n.Load(dataDir, locale)
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
						-- Index templates by (slot count, leading literal) so a
						-- lookup narrows to a handful of candidates instead of
						-- scanning tens of thousands of keys per drawn string.
						local lead = k:match("^([^{]*)")
						if lead and k:find("{", 1, true) then
							local slots = 0
							for _ in k:gmatch("{%d+[^}]*}") do slots = slots + 1 end
							if slots > 0 then
								local bucket = i18n.templates[slots]
								if not bucket then bucket = { } i18n.templates[slots] = bucket end
								-- A template that opens with a placeholder has no
								-- literal prefix to index by; key it on the literal
								-- that follows, which the lookup can derive from the
								-- number it just consumed ("15 points to node" ->
								-- "po", same as "{0} points to node").
								local first = (#lead >= 2 and lead:sub(1, 2))
									or k:match("^{%d+[^}]*}%s*(..)")
								if first and #first > 0 then
									bucket[first] = bucket[first] or { }
									t_insert(bucket[first], k)
								end
							end
						end
						total = total + 1
					end
				end
			else
				ConPrintf("[i18n] skipped %s (bad JSON)", file)
			end
		end
	end
	i18n.loaded = total > 0
	ConPrintf("[i18n] loaded %d entries (%s)", total, locale)
end

-- Exact lookup, plus the one-colon mismatch in both directions: POB appends
-- ":" to some labels and stores it in others ("Current build:" drawn, "Current
-- build" in the dictionary; the reverse for "Compare").
local function probeExact(text)
	local d = i18n.entries[text]
	if d then return d end
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
			-- Literal-prefix templates ("Grants {0}% ...") and leading-placeholder
			-- templates ("{0} points to node") live in different buckets.
			local head = text:sub(1, 2)
			local afterNumber = text:match("^%-?%d+%.?%d*%s*(..)")
			for _, which in ipairs(afterNumber and { head, afterNumber } or { head }) do
				local keys = bucket[which]
				if keys then
					for _, key in ipairs(keys) do
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
