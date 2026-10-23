local M = {}

local function q(s)
	return vim.json.encode(s or "")
end

local function names(e)
	return vim.tbl_map(function(a)
		return vim.trim(a.literal or ((a.given or "") .. " " .. (a.family or "")))
	end, e.author or {})
end

local function year(e)
	local p = e.issued and e.issued["date-parts"]
	local y = p and p[1] and p[1][1]
	return y and y ~= "" and tostring(y) or ""
end

-- Same layout as the obsidian-citation-plugin literature note template.
function M.render(e)
	local key, authors = e["citation-key"] or e.id, names(e)
	local out = { "---", "title: " .. q(e.title), authors[1] and "authors:" or "authors: []" }
	for _, a in ipairs(authors) do
		out[#out + 1] = "  - " .. q(a)
	end
	vim.list_extend(out, {
		"published: " .. q(e["container-title"]),
		"year: " .. year(e),
		"key: " .. key,
		"zotero: zotero://select/items/@" .. key,
		"url: " .. (e.URL or ""),
		"tags:",
		"  - paper",
		"---",
		"",
		"# " .. (e.title or key),
		"",
		"_" .. table.concat(authors, ", ") .. "_",
		e["container-title"] or "",
		"",
		"> [!abstract]",
		"> " .. (e.abstract or ""),
		"",
		"---",
		"",
	})
	return out
end

local function field(name)
	return ([[(select v.value from itemData d join itemDataValues v using(valueID) join fields f using(fieldID)
    where d.itemID = i.itemID and f.fieldName = '%s')]]):format(name)
end

local QUERY = [[
select coalesce(json_group_array(json_object(
  'key', i.key, 'citation-key', %s, 'title', %s, 'abstract', %s, 'URL', %s, 'container-title', coalesce(%s, %s),
  'issued', json_object('date-parts', json_array(json_array(substr(%s, 1, 4)))),
  'author', json((select coalesce(json_group_array(case when c.fieldMode = 1
      then json_object('literal', c.lastName) else json_object('given', c.firstName, 'family', c.lastName) end), '[]')
    from (select * from itemCreators ic join creators using(creatorID)
          where ic.itemID = i.itemID and ic.creatorTypeID = (select creatorTypeID from creatorTypes where creatorType = 'author')
          order by ic.orderIndex) c)))), '[]')
  from items i
  where %s is not null
    and i.itemID not in (select itemID from deletedItems)
    and i.itemTypeID not in (select itemTypeID from itemTypes where typeName in ('attachment', 'note', 'annotation'));
]]

local function uri(path)
	return "file:" .. path:gsub("[%%?# ]", function(c)
		return ("%%%02X"):format(c:byte())
	end) .. "?mode=ro"
end

function M.from_sqlite(db)
	if vim.fn.executable("sqlite3") == 0 then
		return nil, "sqlite3 is not installed"
	end
	local sql = QUERY:format(
		field("citationKey"),
		field("title"),
		field("abstractNote"),
		field("url"),
		field("publicationTitle"),
		field("proceedingsTitle"),
		field("date"),
		field("citationKey")
	)
	local res = vim.system({ "sqlite3", uri(vim.fs.normalize(db)), sql }):wait()
	if res.code ~= 0 then
		return nil, vim.trim(res.stderr)
	end
	return vim.json.decode(res.stdout, { luanil = { object = true, array = true } })
end

-- shortcut: HTTP uses the running profile's personal library; add library selection if groups are needed.
function M.from_api()
	if vim.fn.executable("curl") == 0 then
		return nil, "curl is not installed"
	end
	-- The local API returns the whole personal library when no limit is specified.
	local res = vim.system({
		"curl", "--disable", "--silent", "--show-error", "--noproxy", "*",
		"--connect-timeout", "1", "--max-time", "10", "--write-out", "\n%{http_code}",
		"http://127.0.0.1:23119/api/users/0/items/top?format=json",
	}):wait()
	if res.code ~= 0 then
		return nil, vim.trim(res.stderr)
	end
	local body, status = res.stdout:match("^(.*)\n(%d%d%d)$")
	if status ~= "200" then
		return nil, "HTTP " .. (status or "invalid response")
	end
	local ok, items = pcall(vim.json.decode, body, { luanil = { object = true, array = true } })
	if not ok or type(items) ~= "table" or not vim.islist(items) then
		return nil, "invalid JSON item list"
	end
	local entries = {}
	for _, item in ipairs(items) do
		local data = type(item) == "table" and item.data
		if type(data) ~= "table" or type(item.key) ~= "string" then
			return nil, "invalid API item"
		end
		for _, name in ipairs({ "citationKey", "title", "abstractNote", "url", "publicationTitle", "proceedingsTitle", "date" }) do
			if data[name] ~= nil and type(data[name]) ~= "string" then
				return nil, "invalid API field: " .. name
			end
		end
		if data.citationKey and data.citationKey ~= "" and not data.deleted
			and data.itemType ~= "attachment" and data.itemType ~= "note" and data.itemType ~= "annotation" then
			local authors = {}
			if type(data.creators) ~= "table" or not vim.islist(data.creators) then
				return nil, "invalid API creators"
			end
			for _, creator in ipairs(data.creators) do
				if type(creator) ~= "table" then
					return nil, "invalid API creator"
				end
				for _, name in ipairs({ "name", "firstName", "lastName" }) do
					if creator[name] ~= nil and type(creator[name]) ~= "string" then
						return nil, "invalid API creator name"
					end
				end
				if creator.creatorType == "author" then
					authors[#authors + 1] = { literal = creator.name, given = creator.firstName, family = creator.lastName }
				end
			end
			entries[#entries + 1] = {
				key = item.key, ["citation-key"] = data.citationKey,
				title = data.title, abstract = data.abstractNote, URL = data.url,
				["container-title"] = data.publicationTitle or data.proceedingsTitle,
				issued = { ["date-parts"] = { { (data.date or ""):match("%d%d%d%d") } } },
				author = authors,
			}
		end
	end
	return entries
end

local function load(root, config)
	if config.db == false then
		vim.notify("Citations are disabled", vim.log.levels.INFO)
		return
	end
	local db = vim.fs.normalize(config.db)
	if db:sub(1, 1) ~= "/" then
		db = root .. "/" .. db
	end
	local entries, err
	if db:lower():match("%.json$") then
		entries = require("vault").read_json(db)
		err = "missing or invalid CSL-JSON library"
	else
		local api_err
		entries, api_err = M.from_api()
		if not entries then
			if vim.fn.filereadable(db) == 1 then
				entries, err = M.from_sqlite(db)
			else
				err = "database not found or unreadable"
			end
			if not entries then
				err = "HTTP API: " .. api_err .. "; SQLite: " .. err
					.. ". If Zotero is running, enable extensions.zotero.httpServer.localAPI.enabled in its Config Editor."
			end
		end
	end
	if type(entries) ~= "table" or not vim.islist(entries) then
		vim.notify("Cannot load citations (" .. db .. "): " .. (err or "expected an entry list"), vim.log.levels.ERROR)
		return
	end
	for _, entry in ipairs(entries) do
		local key = type(entry) == "table" and (entry["citation-key"] or entry.id)
		if type(key) ~= "string" or key == "" then
			vim.notify("Invalid citation key in " .. db, vim.log.levels.ERROR)
			return
		end
	end
	return entries
end

-- Zotero's own item-key link; CSL-JSON entries have no item key, so use the Better BibTeX @citekey form.
function M.link(e)
	if e.key then
		return "zotero://select/library/items/" .. e.key
	end
	return "zotero://select/items/@" .. (e["citation-key"] or e.id)
end

local function pick(root, cb)
	local config = require("vault.config").get(root).citations
	local entries = load(root, config)
	if not entries then
		return
	end
	table.sort(entries, function(a, b)
		return (a["citation-key"] or a.id) < (b["citation-key"] or b.id)
	end)
	local dir = root .. "/" .. config.folder
	local items = vim.tbl_map(function(e)
		return { text = ("%s  %s"):format(e["citation-key"] or e.id, e.title or ""), entry = e }
	end, entries)
	Snacks.picker.pick({
		title = "Zotero",
		items = items,
		format = "text",
		preview = "none",
		layout = { preset = "select" },
		confirm = function(picker, item)
			picker:close()
			if item then
				cb(item.entry, dir .. "/@" .. (item.entry["citation-key"] or item.entry.id) .. ".md")
			end
		end,
		actions = {
			zotero_open = function(_, item)
				if item then
					vim.ui.open(M.link(item.entry))
				end
			end,
		},
		win = {
			input = { keys = { ["<c-t>"] = { "zotero_open", mode = { "n", "i" }, desc = "Open in Zotero" } } },
			list = { keys = { ["<c-t>"] = "zotero_open" } },
		},
	})
end

local function ensure(e, path)
	if vim.fn.filereadable(path) == 0 then
		vim.fn.mkdir(vim.fs.dirname(path), "p")
		vim.fn.writefile(M.render(e), path)
	end
end

function M.cite(root)
	pick(root, function(e, path)
		vim.api.nvim_put({ "[[@" .. (e["citation-key"] or e.id) .. "]]" }, "c", true, true)
		ensure(e, path)
	end)
end

function M.open(root)
	pick(root, function(e, path)
		ensure(e, path)
		vim.cmd.edit(vim.fn.fnameescape(path))
	end)
end

return M
