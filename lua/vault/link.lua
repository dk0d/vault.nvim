local M = {}

-- "[[note|alias]]" / "[[note#heading]]" under the 1-based col -> "note"
function M.at_cursor(line, col)
	for s, inner in line:gmatch("()%[%[([^%[%]]+)%]%]") do
		if col >= s and col < s + #inner + 4 then
			return (inner:gsub("[|#].*", ""))
		end
	end
end

local function resolve(root, name)
	local path = root .. "/" .. name .. ".md"
	if vim.fn.filereadable(path) == 1 then
		return path
	end
	return vim.fs.find(vim.fs.basename(name) .. ".md", { path = root, type = "file", limit = 1 })[1]
end

-- Obsidian's new-note location (app.json); a link with a subpath is always relative to the vault root.
local function new_dir(root, name)
	local V = require("vault")
	if name:find("/") then
		return root
	end
	local app = V.read_json(root .. "/.obsidian/app.json") or {}
	if app.newFileLocation == "current" then
		local cur = vim.api.nvim_buf_get_name(0)
		return cur ~= "" and vim.fs.dirname(cur) or root
	end
	local folder = (app.newFileLocation == "folder" and app.newFileFolderPath) or V.opts.notes.folder or ""
	return folder ~= "" and (root .. "/" .. folder) or root
end

function M.open(root)
	local name = M.at_cursor(vim.api.nvim_get_current_line(), vim.fn.col("."))
	if not name or name == "" then
		return vim.notify("No wiki link under the cursor", vim.log.levels.WARN)
	end
	local path = resolve(root, name)
	if not path then
		path = new_dir(root, name) .. "/" .. name .. ".md"
		vim.fn.mkdir(vim.fs.dirname(path), "p")
		vim.fn.writefile(require("vault").frontmatter_lines(), path)
	end
	vim.cmd.edit(vim.fn.fnameescape(path))
end

return M
