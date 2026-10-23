local M = {}

local schema = {
	daily = { format = "string", folder = "string", template = "string" },
	citations = { folder = "string", db = "string|false" },
	notes = { folder = "string" },
	keymaps = { prefix = "string|false" },
}

local escapes = { b = "\b", t = "\t", n = "\n", f = "\f", r = "\r", ['"'] = '"', ["\\"] = "\\" }

local function value(text, fail)
	local quote = text:sub(1, 1)
	if quote ~= '"' and quote ~= "'" then
		local boolean, rest = text:match("^(%a+)(.*)$")
		if boolean == "true" or boolean == "false" then
			return boolean == "true", rest
		end
		fail("expected a quoted string or boolean")
	end
	local out, i = {}, 2
	while i <= #text do
		local c = text:sub(i, i)
		if c == quote then
			return table.concat(out), text:sub(i + 1)
		elseif c == "\\" and quote == '"' then
			i = i + 1
			local e = text:sub(i, i)
			if e == "u" or e == "U" then
				local n = e == "u" and 4 or 8
				local hex = text:sub(i + 1, i + n)
				local code = #hex == n and hex:match("^%x+$") and tonumber(hex, 16)
				if not code or code > 0x10FFFF or (code >= 0xD800 and code <= 0xDFFF) then
					fail("invalid Unicode escape")
				end
				out[#out + 1], i = vim.fn.nr2char(code), i + n
			elseif escapes[e] then
				out[#out + 1] = escapes[e]
			else
				fail("invalid string escape")
			end
		elseif (c:byte() < 32 and c ~= "\t") or c:byte() == 127 then
			fail("control character in string")
		else
			out[#out + 1] = c
		end
		i = i + 1
	end
	fail("unterminated string")
end

-- shortcut: only section headers and scalar strings/booleans are supported; use a full TOML
-- parser if configuration grows to need arrays, dotted keys, or multiline strings.
function M.parse(text, path)
	local result, section = {}, nil
	for number, line in ipairs(vim.split(text, "\n", { plain = true })) do
		local function fail(message)
			error(("%s:%d: %s"):format(path or "vault.toml", number, message), 0)
		end
		line = vim.trim(line)
		if line ~= "" and line:sub(1, 1) ~= "#" then
			local name, rest = line:match("^%[([%w_-]+)%](.*)$")
			if name then
				if not schema[name] then
					fail("unknown section [" .. name .. "]")
				end
				if result[name] then
					fail("duplicate section [" .. name .. "]")
				end
				section, result[name] = name, {}
			else
				local key, raw = line:match("^([%w_-]+)%s*=%s*(.*)$")
				if not key or not section or not schema[section][key] then
					fail("expected a supported key inside a feature section")
				end
				if result[section][key] ~= nil then
					fail("duplicate key " .. key)
				end
				local v
				v, rest = value(raw, fail)
				local kind = schema[section][key]
				if type(v) ~= "string" and not (kind == "string|false" and v == false) then
					fail(section .. "." .. key .. " must be " .. kind)
				end
				result[section][key] = v
			end
			rest = vim.trim(rest)
			if rest ~= "" and rest:sub(1, 1) ~= "#" then
				fail("unexpected text after value or section")
			end
		end
	end
	return result
end

local function read(root)
	for _, name in ipairs({ ".vault.toml", "vault.toml" }) do
		local path = root .. "/" .. name
		local f, err, code = io.open(path)
		if f then
			local text, read_err = f:read("*a")
			f:close()
			if not text then
				error(path .. ": " .. read_err, 0)
			end
			return M.parse(text, path)
		elseif code ~= 2 then -- ENOENT: an absent config is fine; unreadable configs are errors.
			error(err, 0)
		end
	end
	return {}
end

function M.get(root)
	local V = require("vault")
	local toml = read(root)
	local daily = V.read_json(root .. "/.obsidian/daily-notes.json") or {}
	local citations = V.read_json(root .. "/.obsidian/plugins/obsidian-citation-plugin/data.json") or {}
	local app = V.read_json(root .. "/.obsidian/app.json") or {}
	local config = vim.tbl_deep_extend("force", {
		daily = V.opts.daily,
		citations = V.opts.citations,
		notes = V.opts.notes,
		keymaps = { prefix = V.opts.prefix },
	}, {
		daily = daily,
		citations = { folder = citations.literatureNoteFolder, db = citations.citationExportPath },
		notes = { folder = app.newFileLocation == "folder" and app.newFileFolderPath or nil },
	}, toml)
	config.notes.current = app.newFileLocation == "current" and not (toml.notes and toml.notes.folder ~= nil)
	return config
end

return M
