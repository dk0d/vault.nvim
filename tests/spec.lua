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
	assert(V.opts.papers.folder == "papers" and V.opts.daily.format == "YYYY.MM.DD")
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
