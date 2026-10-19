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

-- shortcut: read-only URI works while Zotero is open (WAL) but fails with "database is locked" if Zotero
-- holds an exclusive lock (dbLockExclusive); add a copy-the-db fallback if that ever bites.
local function uri(path)
	return "file:" .. path:gsub("[%%?# ]", function(c)
		return ("%%%02X"):format(c:byte())
	end) .. "?mode=ro"
end

function M.from_sqlite(db)
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

local function load(root, plugin)
	local db = vim.fn.expand(require("vault").opts.zotero_db or "")
	if db ~= "" and vim.uv.fs_stat(db) then
		local entries, err = M.from_sqlite(db)
		if not entries then
			vim.notify("Zotero sqlite failed: " .. err, vim.log.levels.ERROR)
		end
		return entries
	end
	local bib = root .. "/" .. (plugin.citationExportPath or require("vault").opts.papers.csl_json)
	local entries = require("vault").read_json(bib)
	if not entries then
		vim.notify("No Zotero db or CSL-JSON library found (" .. bib .. ")", vim.log.levels.ERROR)
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
	local plugin = require("vault").read_json(root .. "/.obsidian/plugins/obsidian-citation-plugin/data.json") or {}
	local entries = load(root, plugin)
	if not entries then
		return
	end
	table.sort(entries, function(a, b)
		return a["citation-key"] < b["citation-key"]
	end)
	local dir = root .. "/" .. (plugin.literatureNoteFolder or require("vault").opts.papers.folder)
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
