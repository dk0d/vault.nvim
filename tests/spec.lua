-- Run from the plugin root: nvim -l tests/spec.lua
vim.opt.rtp:prepend(".")
local d = require("vault.daily")

assert(d.strftime_fmt("YYYY-MM-DD [[daily]]") == "%Y-%m-%d [daily]")
local parse = d.parser("YYYY-MM-DD [[daily]]")
assert(parse("2026-10-19 [daily].md") == 20261019)
assert(parse("notes.md") == nil)
assert(parse(os.date(d.strftime_fmt("YYYY-MM-DD [[daily]]")) .. ".md") == tonumber(os.date("%Y%m%d")))
assert(d.parser("DD.MM.YYYY")("05.03.2025.md") == 20250305)

local note = table.concat(
  require("vault.zotero").render({
    ["citation-key"] = "k2020",
    title = 'A "quoted": title',
    author = { { given = "Ada", family = "Lovelace" }, { literal = "Others" } },
    issued = { ["date-parts"] = { { "2020", 5 } } },
  }),
  "\n"
)
assert(note:find('title: "A \\"quoted\\": title"', 1, true))
assert(note:find("  - \"Ada Lovelace\"", 1, true) and note:find("year: 2020", 1, true))
print("ok")

local db = vim.fn.expand("~/Zotero/zotero.sqlite")
if vim.uv.fs_stat(db) then
  local entries = assert(require("vault.zotero").from_sqlite(db))
  local e = assert(entries[1])
  assert(e["citation-key"] and e.title and e.author, "sqlite entry malformed")
  for _, x in ipairs(entries) do assert(type(table.concat(require("vault.zotero").render(x), "\n")) == "string") end
  print("sqlite ok:", #entries, "entries")
end

-- Vault TOML parsing, per-value precedence, reloads, and feature integration.
do
	local V, config = require("vault"), require("vault.config")
	local original = vim.deepcopy(V.opts)
	V.setup({})
	local parsed = config.parse([=[
# Strings preserve comments and brackets inside quotes.
[daily] # journal settings
folder = 'daily # notes'
format = "YYYY-MM-DD [\"day\"]"
template = "templates/\u0064\U00000061ily"
[citations]
db = false # disable citations
[keymaps]
prefix = "\\v"
]=])
	assert(parsed.daily.folder == "daily # notes")
	assert(parsed.daily.format == 'YYYY-MM-DD ["day"]')
	assert(parsed.daily.template == "templates/daily")
	assert(parsed.citations.db == false and parsed.keymaps.prefix == "\\v")
	assert(config.parse("[notes]\r\nfolder = ''\r\n").notes.folder == "")
	for _, invalid in ipairs({
		'[daily]\nfolder = "unterminated',
		'[daily]\nfolder = "bad\\q"',
		'[daily]\nfolder = "\\uD800"',
		'[daily]\nfolder = "\\U00110000"',
		'[daily]\nfolder = "ok" garbage',
		'[daily]\nfolder = ""\nfolder = "again"',
		'[daily]\n[daily]',
		'[daily] garbage',
		'[daily]\nfolder = false',
		'[citations]\ndb = true',
		'[keymaps]\nprefix = false\nprefix = "again"',
		'[unknown]',
		'[daily]\nfodler = "typo"',
		'folder = "no section"',
		'[daily]\nfolder = ["array"]',
	}) do
		local ok, err = pcall(config.parse, invalid, "bad.toml")
		assert(not ok and err:match("bad.toml:%d+:"), "invalid config accepted: " .. invalid)
	end

	local tmp = vim.fn.tempname()
	vim.fn.mkdir(tmp .. "/.obsidian/plugins/obsidian-citation-plugin", "p")
	tmp = vim.uv.fs_realpath(tmp)
	vim.fn.mkdir(tmp .. "/sub", "p")
	vim.fn.mkdir(tmp .. "/templates", "p")
	vim.fn.writefile({ "# local template" }, tmp .. "/templates/daily.md")
	vim.fn.writefile({ '{"folder":"obsidian-daily","format":"YYYY.MM.DD"}' }, tmp .. "/.obsidian/daily-notes.json")
	vim.fn.writefile({ '{"newFileLocation":"current"}' }, tmp .. "/.obsidian/app.json")
	vim.fn.writefile({ '{"literatureNoteFolder":"obsidian-papers","citationExportPath":"missing.json"}' },
		tmp .. "/.obsidian/plugins/obsidian-citation-plugin/data.json")
	local public = tmp .. "/vault.toml"
	local hidden = tmp .. "/.vault.toml"
	vim.fn.writefile({ '[daily]', 'folder = "toml-daily"', 'template = "templates/daily"' }, public)
	local c = config.get(tmp)
	assert(c.daily.folder == "toml-daily" and c.daily.format == "YYYY.MM.DD")
	assert(c.citations.folder == "obsidian-papers" and c.citations.db == "missing.json" and c.notes.current)
	assert(vim.deep_equal(V.opts, original), "vault config mutated setup options")
	d.today(tmp)
	assert(vim.fn.readfile(tmp .. "/toml-daily/" .. os.date("%Y.%m.%d") .. ".md")[1] == "# local template")
	assert(V.root() == tmp, "vault root not detected")
	vim.fn.writefile({ "previous" }, tmp .. "/toml-daily/2000.01.01.md")
	d.step(tmp, -1)
	assert(vim.api.nvim_buf_get_name(0) == tmp .. "/toml-daily/2000.01.01.md")

	vim.fn.writefile({
		'[daily]', 'folder = "hidden-daily"', 'template = ""',
		'[notes]', 'folder = "inbox"',
		'[citations]', 'folder = "literature"', 'db = false',
		'[keymaps]', 'prefix = ",v"',
	}, hidden)
	c = config.get(tmp)
	assert(c.daily.folder == "hidden-daily" and c.daily.template == "")
	assert(c.notes.folder == "inbox" and not c.notes.current)
	assert(c.citations.db == false and c.keymaps.prefix == ",v")
	d.today(tmp)
	assert(#vim.fn.readfile(tmp .. "/hidden-daily/" .. os.date("%Y.%m.%d") .. ".md") == 0)
	vim.cmd.edit(vim.fn.fnameescape(tmp .. "/sub/source.md"))
	vim.bo.filetype = "markdown"
	assert(vim.fn.maparg(",vd", "n") == "<Cmd>VaultDaily<CR>", "local keymap prefix not used")
	vim.api.nvim_buf_set_lines(0, 0, -1, false, { "[[local note]]" })
	vim.api.nvim_win_set_cursor(0, { 1, 3 })
	require("vault.link").open(tmp)
	assert(vim.fn.filereadable(tmp .. "/inbox/local note.md") == 1, "TOML did not override current-folder location")

	vim.fn.writefile({ '[notes]', 'folder = ""', '[keymaps]', 'prefix = false' }, hidden)
	vim.cmd.edit(vim.fn.fnameescape(tmp .. "/sub/another.md"))
	vim.bo.filetype = "markdown"
	assert(vim.fn.maparg("<leader>vd", "n") == "" and vim.fn.maparg(",vd", "n") == "", "keymaps not disabled")
	vim.api.nvim_buf_set_lines(0, 0, -1, false, { "[[root note]]" })
	vim.api.nvim_win_set_cursor(0, { 1, 3 })
	require("vault.link").open(tmp)
	assert(vim.fn.filereadable(tmp .. "/root note.md") == 1, "empty folder did not override current-folder location")
	assert(config.get(tmp).daily.folder == "obsidian-daily", "both TOML files were merged")

	vim.fn.writefile({ '[citations]', 'folder = "literature"', 'db = "library.json"' }, hidden)
	local entries = { { ["citation-key"] = "z-last" }, { id = "toml-paper", title = "Local library" } }
	vim.fn.writefile({ vim.json.encode(entries) }, tmp .. "/library.json")
	local z, snacks = require("vault.zotero"), _G.Snacks
	local sqlite = z.from_sqlite
	z.from_sqlite = function() error("CSL-JSON was read as SQLite") end
	_G.Snacks = { picker = { pick = function(opts)
		assert(#opts.items == 2 and opts.items[1].entry.title == "Local library")
		opts.confirm({ close = function() end }, opts.items[1])
	end } }
	z.open(tmp)
	assert(vim.fn.filereadable(tmp .. "/literature/@toml-paper.md") == 1, "paper folder not used")
	vim.fn.writefile({ '[citations]', 'db = "' .. tmp .. '/library.json"' }, hidden)
	z.cite(tmp)
	assert(vim.api.nvim_get_current_line():find("[[@toml-paper]]", 1, true), "CSL-JSON citation not inserted")

	vim.fn.writefile({}, tmp .. "/library.sqlite")
	z.from_sqlite = function(path)
		assert(path == tmp .. "/library.sqlite", "SQLite path not relative to vault")
		return entries
	end
	vim.fn.writefile({ '[citations]', 'db = "library.sqlite"' }, hidden)
	z.open(tmp)

	local notify, notices = vim.notify, {}
	vim.notify = function(message, level) notices[#notices + 1] = { message, level } end
	_G.Snacks.picker.pick = function() error("disabled or invalid citations opened a picker") end
	z.from_sqlite = function() error("disabled or missing database was read") end
	vim.fn.writefile({ '[citations]', 'db = false' }, hidden)
	local before = vim.api.nvim_buf_get_lines(0, 0, -1, false)
	z.cite(tmp)
	z.open(tmp)
	assert(#notices == 2 and notices[1][2] == vim.log.levels.INFO)
	assert(vim.deep_equal(before, vim.api.nvim_buf_get_lines(0, 0, -1, false)), "disabled citations changed the buffer")
	for _, source in ipairs({ "missing.sqlite", "missing.json", "invalid.json" }) do
		vim.fn.writefile({ '[citations]', 'db = "' .. source .. '"' }, hidden)
		vim.fn.writefile({ '{"not":"a library"}' }, tmp .. "/invalid.json")
		z.open(tmp)
		assert(notices[#notices][2] == vim.log.levels.ERROR, "invalid database not reported")
	end
	_G.Snacks, z.from_sqlite, vim.notify = snacks, sqlite, notify

	vim.fn.writefile({ '[daily]', 'folder = false' }, hidden)
	local ok, err = pcall(d.today, tmp)
	assert(not ok and err:find(hidden .. ":2:", 1, true), "bad config should stop note creation")
	vim.fn.writefile({}, hidden)
	assert(config.get(tmp).daily.folder == "obsidian-daily", "empty marker should use fallbacks")
	vim.fn.delete(hidden)
	assert(config.get(tmp).daily.folder == "toml-daily", "public config not reloaded")
	vim.fn.delete(public)
	assert(config.get(tmp).daily.folder == "obsidian-daily", "deleted config still in use")
	local other = vim.fn.tempname()
	vim.fn.mkdir(other, "p")
	other = vim.uv.fs_realpath(other)
	assert(vim.deep_equal(config.get(other).daily, V.opts.daily), "settings leaked into another vault")
	vim.fn.writefile({ '[daily]', 'folder = "standalone"' }, other .. "/vault.toml")
	d.today(other)
	assert(V.root() == other and vim.fn.filereadable(other .. "/standalone/" .. os.date("%Y-%m-%d") .. ".md") == 1,
		"TOML-only vault not configured or detected")
	assert(vim.deep_equal(V.opts, original), "feature config mutated setup options")
	vim.fn.delete(tmp, "rf")
	vim.fn.delete(other, "rf")
	print("vault TOML ok")
end

-- config precedence: obsidian file > setup() opts > built-in defaults
do
	local V, daily = require("vault"), require("vault.daily")
	local tmp = vim.fn.tempname()
	vim.fn.mkdir(tmp .. "/tpl", "p")
	vim.fn.writefile({ "# <% tp.date.now(\"YYYY\") %>" }, tmp .. "/tpl/d.md")
	local y = os.date("%Y")

	V.setup({ daily = { format = "YYYY.MM.DD", folder = "journal", template = "tpl/d" } })
	daily.today(tmp) -- no .obsidian at all -> setup() values
	local want = tmp .. "/journal/" .. os.date("%Y.%m.%d") .. ".md"
	assert(vim.fn.filereadable(want) == 1, "opts not used: " .. want)
	assert(vim.fn.readfile(want)[1] == "# " .. y, "opts template not used")

	vim.fn.mkdir(tmp .. "/.obsidian", "p")
	vim.fn.writefile({ vim.json.encode({ folder = "daily" }) }, tmp .. "/.obsidian/daily-notes.json")
	daily.today(tmp) -- partial obsidian file: folder from obsidian, format/template from opts
	assert(vim.fn.filereadable(tmp .. "/daily/" .. os.date("%Y.%m.%d") .. ".md") == 1, "partial merge failed")

	V.setup({}) -- opts persist across setup calls; defaults for the rest
	assert(V.opts.citations.folder == "papers" and V.opts.daily.format == "YYYY.MM.DD")
	print("config precedence ok")
end

do
	local z = require("vault.zotero")
	assert(z.link({ key = "ABCD1234", ["citation-key"] = "k" }) == "zotero://select/library/items/ABCD1234")
	assert(z.link({ ["citation-key"] = "k2020" }) == "zotero://select/items/@k2020")
	print("zotero link ok")
end

do
	local link = require("vault.link")
	assert(link.at_cursor("see [[my note]] here", 5) == "my note")
	assert(link.at_cursor("see [[my note]] here", 15) == "my note") -- on the closing ]]
	assert(link.at_cursor("see [[my note]] here", 16) == nil)
	assert(link.at_cursor("see [[note|alias]]", 8) == "note")
	assert(link.at_cursor("see [[note#head]]", 8) == "note")
	assert(link.at_cursor("[[a]] and [[b]]", 12) == "b")
	assert(link.at_cursor("no links here", 3) == nil)

	local tmp = vim.fn.tempname()
	vim.fn.mkdir(tmp .. "/sub", "p")
	vim.fn.writefile({ "x" }, tmp .. "/sub/existing.md")
	require("vault").setup({ notes = { folder = "inbox" } })
	vim.api.nvim_buf_set_lines(0, 0, -1, false, { "link to [[missing note]]" })
	vim.api.nvim_win_set_cursor(0, { 1, 12 })
	link.open(tmp)
	assert(vim.fn.filereadable(tmp .. "/inbox/missing note.md") == 1, "note not created in notes.folder")
	assert(vim.fn.readfile(tmp .. "/inbox/missing note.md")[2]:find("^created: "), "no front-matter")

	vim.cmd.enew()
	vim.api.nvim_buf_set_lines(0, 0, -1, false, { "link to [[existing]]" })
	vim.api.nvim_win_set_cursor(0, { 1, 12 })
	link.open(tmp)
	assert(vim.api.nvim_buf_get_name(0):find("/sub/existing.md$"), "did not open the existing note")
	print("link ok")
end
