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
		pieces[#pieces + 1] = { slot = key:sub(b + 1, c - 1) }
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
	return (template:gsub("{(%d+)}", function(slot)
		local v = values[slot]
		if v == nil then return "{" .. slot .. "}" end
		return v
	end))
end

function i18n.Load(dataDir, locale)
	i18n.entries = { }
	i18n.templates = { }   -- placeholder keys, grouped by slot count
	i18n.byFirstChar = { } -- optimisation: bucket by first byte
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
						-- Index templates by (slot count, leading literal) so a
						-- lookup narrows to a handful of candidates instead of
						-- scanning tens of thousands of keys per drawn string.
						local lead = k:match("^([^{]*)")
						if lead and k:find("{", 1, true) then
							local slots = 0
							for _ in k:gmatch("{%d+}") do slots = slots + 1 end
							if slots > 0 and #lead >= 2 then
								local bucket = i18n.templates[slots]
								if not bucket then bucket = { } i18n.templates[slots] = bucket end
								local first = lead:sub(1, 2)
								bucket[first] = bucket[first] or { }
								t_insert(bucket[first], k)
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
	if text:sub(-1) == ":" then
		return i18n.entries[text:sub(1, -2)]
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
		local keys = bucket and bucket[text:sub(1, 2)]
		if keys then
			for _, key in ipairs(keys) do
				local values = matchPlaceholders(key, text)
				if values then
					return fillPlaceholders(i18n.entries[key], values)
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
		local q = text:find(": ", 1, true)
		if q and q > 1 then
			local head = probeExact(text:sub(1, q - 1))
			if head then return head .. text:sub(q) end
		end
	end
	return text
end

-- Translate a string that may carry colour escapes, keeping the escapes.
function i18n.TranslateColoured(text)
	if not i18n.loaded or type(text) ~= "string" then return text end
	local direct = i18n.entries[text]
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
