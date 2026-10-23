-- Run via tests/spec.lua: use a real SQLite fixture and mock only the HTTP process boundary.
local V, z = require("vault"), require("vault.zotero")
local opts, system, snacks, notify = vim.deepcopy(V.opts), vim.system, _G.Snacks, vim.notify
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local db = tmp .. "/zotero.sqlite"
local created = system({ "sqlite3", db }, { stdin = [[
CREATE TABLE items (itemID INTEGER, key TEXT, itemTypeID INTEGER);
CREATE TABLE itemTypes (itemTypeID INTEGER, typeName TEXT);
CREATE TABLE deletedItems (itemID INTEGER);
CREATE TABLE itemData (itemID INTEGER, fieldID INTEGER, valueID INTEGER);
CREATE TABLE itemDataValues (valueID INTEGER, value TEXT);
CREATE TABLE fields (fieldID INTEGER, fieldName TEXT);
CREATE TABLE itemCreators (itemID INTEGER, creatorID INTEGER, creatorTypeID INTEGER, orderIndex INTEGER);
CREATE TABLE creators (creatorID INTEGER, fieldMode INTEGER, firstName TEXT, lastName TEXT);
CREATE TABLE creatorTypes (creatorTypeID INTEGER, creatorType TEXT);
INSERT INTO itemTypes VALUES (1, 'journalArticle'), (2, 'note');
INSERT INTO items VALUES (1, 'ABCD1234', 1), (2, 'DELETED1', 1), (3, 'NOTE1234', 2), (4, 'NOKEY123', 1);
INSERT INTO deletedItems VALUES (2);
INSERT INTO fields VALUES (1, 'citationKey'), (2, 'title'), (3, 'date'), (4, 'publicationTitle');
INSERT INTO itemDataValues VALUES (1, 'ada2020'), (2, 'A paper'), (3, '2020-03-01'), (4, 'A journal');
INSERT INTO itemData VALUES (1, 1, 1), (1, 2, 2), (1, 3, 3), (1, 4, 4), (2, 1, 1), (3, 1, 1);
INSERT INTO creatorTypes VALUES (1, 'author'), (2, 'editor');
INSERT INTO creators VALUES (1, 0, 'Ada', 'Lovelace'), (2, 1, '', 'A team'), (3, 0, 'An', 'Editor');
INSERT INTO itemCreators VALUES (1, 1, 1, 0), (1, 2, 1, 1), (1, 3, 2, 2);
]] }):wait()
assert(created.code == 0, created.stderr)
local sqlite = assert(z.from_sqlite(db))
assert(#sqlite == 1 and sqlite[1]["citation-key"] == "ada2020")
assert(#sqlite[1].author == 2 and sqlite[1].author[2].literal == "A team")

local item = {
	key = "ABCD1234",
	data = {
		itemType = "journalArticle", citationKey = "ada2020", title = "A paper",
		date = "2020-03-01", publicationTitle = "A journal",
		creators = {
			{ creatorType = "author", firstName = "Ada", lastName = "Lovelace" },
			{ creatorType = "author", name = "A team" },
			{ creatorType = "editor", firstName = "An", lastName = "Editor" },
		},
	},
}
local response, calls, picked, message, locked
local function http(body, status)
	return { code = 0, stdout = body .. "\n" .. (status or "200"), stderr = "" }
end
vim.system = function(cmd, options)
	calls[#calls + 1] = cmd[1]
	if cmd[1] == "curl" then
		assert(cmd[#cmd] == "http://127.0.0.1:23119/api/users/0/items/top?format=json")
		assert(vim.tbl_contains(cmd, "--max-time") and vim.tbl_contains(cmd, "--noproxy"))
		return { wait = function() return response end }
	end
	assert(cmd[1] == "sqlite3")
	if locked then
		return { wait = function() return { code = 1, stderr = "database is locked (5)" } end }
	end
	return system(cmd, options)
end
_G.Snacks = { picker = { pick = function(p) picked = p.items end } }
vim.notify = function(text) message = text end
V.opts.citations = { db = db, folder = "papers" }
local function open(result)
	response, calls, picked, message = result, {}, nil, nil
	z.open(tmp)
end

local unkeyed = { key = "NOKEY123", data = { itemType = "book" } }
open(http(vim.json.encode({ item, unkeyed })))
assert(vim.deep_equal(calls, { "curl" }), "successful API should bypass SQLite")
assert(#picked == 1 and picked[1].entry.key == "ABCD1234")
assert(vim.deep_equal(z.render(picked[1].entry), z.render(sqlite[1])), "HTTP and SQLite notes differ")
assert(z.link(picked[1].entry) == "zotero://select/library/items/ABCD1234")

open(http("[]"))
assert(#picked == 0 and #calls == 1, "empty library must not trigger SQLite")
V.opts.citations.db = tmp .. "/missing.sqlite"
open(http(vim.json.encode({ item })))
assert(#picked == 1 and #calls == 1, "HTTP must run before checking the database file")
V.opts.citations.db = db

local bad_item = vim.deepcopy(item)
bad_item.data.creators = "invalid"
for _, failure in ipairs({
	{ code = 7, stderr = "connection refused" },
	{ code = 28, stderr = "request timed out" },
	http("Local API is not enabled", "403"),
	http("Internal error", "500"),
	http("not JSON"),
	http('{"error":"not a list"}'),
	http('[{"key":"ABCD1234"}]'),
	http(vim.json.encode({ bad_item })),
}) do
	open(failure)
	assert(vim.deep_equal(calls, { "curl", "sqlite3" }), "failed API did not fall back to SQLite")
	assert(#picked == 1 and picked[1].entry["citation-key"] == "ada2020" and not message)
end

locked = true
open(http("Local API is not enabled", "403"))
assert(not picked and message:find("HTTP 403", 1, true) and message:find("database is locked", 1, true))
assert(message:find("extensions.zotero.httpServer.localAPI.enabled", 1, true))

V.opts, vim.system, _G.Snacks, vim.notify = opts, system, snacks, notify
vim.fn.delete(tmp, "rf")
print("Zotero HTTP-first / SQLite fallback ok")
