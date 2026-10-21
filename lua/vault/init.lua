local M = {}

function M.read_json(path)
	local f = io.open(path)
	if not f then
		return
	end
	local ok, data = pcall(vim.json.decode, f:read("*a"))
	f:close()
	return ok and data or nil
end

local function tasks(root, all)
	Snacks.picker.grep({
		title = all and "Vault tasks (all)" or "Vault tasks",
		cwd = root,
		dirs = { root },
		glob = "*.md",
		search = all and [[^\s*[-*+] \[.\] ]] or [[^\s*[-*+] \[ \] ]],
		live = false,
	})
end

function M.frontmatter_lines()
	return { "---", "created: " .. os.date("%Y.%m.%d %H:%M"), "tags: []", "---", "" }
end

local function frontmatter(buf)
	if vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "---" then
		return vim.notify("Front-matter already exists", vim.log.levels.WARN)
	end
	vim.api.nvim_buf_set_lines(buf, 0, 0, false, M.frontmatter_lines())
end

-- one group in vim.fs.root = equal priority, so the nearest marker wins
M.markers = { ".obsidian", ".vault.toml", "vault.toml" }

local function root()
	local name = vim.api.nvim_buf_get_name(0)
	return vim.fs.root(name ~= "" and name or vim.uv.cwd() or ".", { M.markers })
end
M.root = root

local function define_commands()
	local function cmd(name, desc, fn, opts)
		vim.api.nvim_create_user_command(name, function(o)
			local r = root()
			if not r then
				return vim.notify("Not in an Obsidian vault", vim.log.levels.ERROR)
			end
			fn(r, o)
		end, vim.tbl_extend("force", opts or {}, { desc = desc }))
	end
	local daily, zotero =
		function()
			return require("vault.daily")
		end, function()
			return require("vault.zotero")
		end
	cmd("VaultDaily", "Open/create today's daily note", function(r)
		daily().today(r)
	end)
	cmd("VaultDailyNext", "Next daily note", function(r)
		daily().step(r, 1)
	end)
	cmd("VaultDailyPrev", "Previous daily note", function(r)
		daily().step(r, -1)
	end)
	cmd("VaultFrontmatter", "Insert YAML front-matter", function()
		frontmatter(0)
	end)
	cmd("VaultTasks", "Search open tasks (! for all)", function(r, o)
		tasks(r, o.bang)
	end, { bang = true })
	cmd("VaultCite", "Insert Zotero citation + create paper note", function(r)
		zotero().cite(r)
	end)
	cmd("VaultPaper", "Open/create Zotero paper note", function(r)
		zotero().open(r)
	end)
	cmd("VaultOpen", "Open the wiki link under the cursor, creating the note if missing", function(r)
		require("vault.link").open(r)
	end)
end

local function keymaps(buf)
	local p = M.opts.prefix
	if not p then
		return
	end
	for lhs, name in pairs({
		d = "Daily",
		n = "DailyNext",
		p = "DailyPrev",
		f = "Frontmatter",
		t = "Tasks",
		c = "Cite",
		z = "Paper",
		o = "Open",
	}) do
		vim.keymap.set("n", p .. lhs, "<cmd>Vault" .. name .. "<cr>", { buffer = buf, desc = "Vault: " .. name })
	end
end

-- Obsidian's own settings win; these apply when the vault has none (or no .obsidian/ at all).
M.opts = {
	prefix = "<leader>v", -- false disables keymaps
	-- path to zotero.sqlite; falls back to the vault's CSL-JSON export if false or the file is missing
	zotero_db = "~/Zotero/zotero.sqlite",
	daily = {
		format = "YYYY-MM-DD", -- moment.js format
		folder = "", -- relative to the vault root
		template = nil, -- relative to the vault root, e.g. "templates/daily"
	},
	papers = {
		folder = "papers", -- where Zotero paper notes are created
		csl_json = "assets/bib/zotero.json", -- CSL-JSON library, used when zotero_db is unavailable
	},
	notes = {
		folder = "", -- where :VaultOpen creates missing notes, relative to the vault root
	},
}

local function activate()
	if root() and not vim.g.vault_active then
		vim.g.vault_active = true
		define_commands()
	end
	return vim.g.vault_active
end

function M.setup(opts)
	M.opts = vim.tbl_deep_extend("force", M.opts, opts or {})
	local g = vim.api.nvim_create_augroup("vault.nvim", { clear = true })
	vim.api.nvim_create_autocmd({ "VimEnter", "BufEnter", "DirChanged" }, { group = g, callback = activate })
	vim.api.nvim_create_autocmd("FileType", {
		group = g,
		pattern = "markdown",
		callback = function(a)
			if activate() and root() then
				keymaps(a.buf)
			end
		end,
	})
end

return M
