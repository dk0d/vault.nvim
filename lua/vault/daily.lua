local M = {}

local TOKENS = { YYYY = "%Y", MM = "%m", DD = "%d", HH = "%H", mm = "%M" }

-- moment.js format (as stored by Obsidian) -> strftime. Only the tokens in TOKENS; [x] is a literal.
function M.strftime_fmt(f)
	f = f:gsub("%%", "%%%%")
	local out, i = {}, 1
	while i <= #f do
		local lit = f:match("^%[(.-)%]", i)
		local tok = TOKENS[f:sub(i, i + 3)] and f:sub(i, i + 3) or TOKENS[f:sub(i, i + 1)] and f:sub(i, i + 1)
		if lit then
			out[#out + 1], i = lit, i + #lit + 2
		elseif tok then
			out[#out + 1], i = TOKENS[tok], i + #tok
		else
			out[#out + 1], i = f:sub(i, i), i + 1
		end
	end
	return table.concat(out)
end

-- Returns fn(filename) -> sortable YYYYMMDD number, or nil if it isn't a daily note.
function M.parser(format)
	local order = {}
	local pat = vim.pesc(M.strftime_fmt(format)):gsub("%%%%([Ymd])", function(c)
		order[#order + 1] = c
		return c == "Y" and "(%d%d%d%d)" or "(%d%d)"
	end)
	return function(name)
		local c = { name:match("^" .. pat .. "%.md$") }
		if #c ~= #order or #c == 0 then
			return
		end
		local d = {}
		for i, k in ipairs(order) do
			d[k] = tonumber(c[i])
		end
		return d.Y * 10000 + d.m * 100 + d.d
	end
end

local function config(root)
	local c = require("vault.config").get(root).daily
	local folder = c.folder
	return {
		format = c.format,
		dir = folder ~= "" and (root .. "/" .. folder) or root,
		template = c.template,
	}
end

-- Templater's `<% tp.date.now("fmt") %>` is the only tag supported; others are left untouched.
local function template_lines(root, template)
	if not template or template == "" then
		return {}
	end
	local path = root .. "/" .. template
	path = path:match("%.md$") and path or path .. ".md"
	if vim.fn.filereadable(path) == 0 then
		return {}
	end
	return vim.tbl_map(function(l)
		return (
			l:gsub('<%%%s*tp%.date%.now%("([^"]*)"%)%s*%%>', function(f)
				return os.date(M.strftime_fmt(f))
			end)
		)
	end, vim.fn.readfile(path))
end

function M.today(root)
	local c = config(root)
	local path = c.dir .. "/" .. os.date(M.strftime_fmt(c.format)) .. ".md"
	if vim.fn.filereadable(path) == 0 then
		vim.fn.mkdir(c.dir, "p")
		vim.fn.writefile(template_lines(root, c.template), path)
	end
	vim.cmd.edit(vim.fn.fnameescape(path))
end

-- Moves between *existing* daily notes; relative to today if the current buffer isn't one.
function M.step(root, dir)
	local c = config(root)
	local parse = M.parser(c.format)
	local cur = parse(vim.fs.basename(vim.api.nvim_buf_get_name(0)))
		or parse(os.date(M.strftime_fmt(c.format)) .. ".md")
	local best, best_name
	for name in vim.fs.dir(c.dir) do
		local k = parse(name)
		if k and (dir > 0 and k > cur and (not best or k < best) or dir < 0 and k < cur and (not best or k > best)) then
			best, best_name = k, name
		end
	end
	if not best_name then
		return vim.notify(dir > 0 and "No next daily note" or "No previous daily note", vim.log.levels.INFO)
	end
	vim.cmd.edit(vim.fn.fnameescape(c.dir .. "/" .. best_name))
end

return M
