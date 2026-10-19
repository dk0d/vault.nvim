# vault.nvim

Obsidian-style features for Neovim. Open a file inside an Obsidian vault and the `:Vault*` commands and
markdown keymaps appear; outside a vault the plugin does nothing.

- Daily notes: open/create today's note, jump to the previous/next one
- YAML front-matter generation
- Task search (`- [ ]`) with a fuzzy picker
- Zotero: insert citations and auto-create a literature note for the cited paper

It reads your existing Obsidian settings, so there is nothing to configure twice.

## Requirements

- Neovim >= 0.10 (developed and tested on 0.12; uses `vim.system` and `vim.fs.root`)
- [snacks.nvim](https://github.com/folke/snacks.nvim) (task picker) and [ripgrep](https://github.com/BurntSushi/ripgrep)
- `sqlite3` on your `PATH` (only for reading Zotero directly)

## Installation

[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "dk0d/vault.nvim", -- or dir = "~/Developer/vault.nvim" for a local checkout
  lazy = false, -- must load at startup so it can detect the vault
  dependencies = { "folke/snacks.nvim" },
  opts = {},
}
```

## How a vault is detected

A buffer is in a vault if a parent directory contains `.obsidian/`, `.vault.toml` or `vault.toml`
(the nearest one wins; the toml files can be empty and are only markers). Without `.obsidian/` the daily-note
and paper settings come from `setup()` (see [Options](#options)). Commands are defined once the first
vault file is opened (or you `:cd` into one). Keymaps are set only on markdown buffers.

## Obsidian settings it reads

The plugin reads these values from the vault's `.obsidian/` folder, on every use (no caching, so changes in
Obsidian apply immediately). Nothing is ever written there.

**Precedence, per value:** the Obsidian setting, then your `setup()` option, then the built-in default. So the
plugin works in a vault with no `.obsidian/` at all (e.g. one marked by `vault.toml`), and a partial Obsidian
file only overrides the keys it actually contains. The last column shows the matching `setup()` option and its default.

| File | Key | Used for | `setup()` option = default |
|---|---|---|---|
| `.obsidian/daily-notes.json` | `format` | Daily note filename (moment.js format, e.g. `YYYY-MM-DD [[daily]]`) | `daily.format` = `YYYY-MM-DD` |
| `.obsidian/daily-notes.json` | `folder` | Folder holding daily notes, relative to the vault root | `daily.folder` = vault root |
| `.obsidian/daily-notes.json` | `template` | Template file for new daily notes, relative to the vault root (`.md` optional) | `daily.template` = none (empty file) |
| `.obsidian/plugins/obsidian-citation-plugin/data.json` | `literatureNoteFolder` | Folder for new paper notes | `papers.folder` = `papers` |
| `.obsidian/plugins/obsidian-citation-plugin/data.json` | `citationExportPath` | CSL-JSON library, only used when `zotero_db` is `false` or the file is missing | `papers.csl_json` = `assets/bib/zotero.json` |

**Not read** (hardcoded, even if you have the setting in Obsidian):

- Core Templates plugin (`templates.json`), including its folder and date format. Only the daily note template is used.
- Citation plugin's note templates: title is always `@<citekey>.md`, the inserted citation is always `[[@<citekey>]]`,
  and the note body is a fixed layout (see [Zotero](#zotero)), not your `literatureNoteContentTemplate`.
- `app.json` (new-note location, link style), `zotero.json` / Zotero Integration plugin settings, hotkeys, and
  every other core or community plugin setting.

## Options

```lua
require("vault").setup({
  prefix = "<leader>v",                 -- keymap prefix; false disables all keymaps
  zotero_db = "~/Zotero/zotero.sqlite", -- false/missing file = use the CSL-JSON export instead
  daily = {                             -- used when .obsidian/daily-notes.json lacks the key
    format = "YYYY-MM-DD",              -- moment.js format
    folder = "",                        -- relative to the vault root
    template = nil,                     -- relative to the vault root, e.g. "templates/daily"
  },
  papers = {
    folder = "papers",                  -- where Zotero paper notes are created
    csl_json = "assets/bib/zotero.json", -- CSL-JSON library, when zotero_db is unavailable
  },
})
```

These are the defaults. `opts = {}` is enough unless you want to change something; tables merge, so
`opts = { daily = { folder = "journal" } }` keeps the other daily defaults.

Example for a vault with no Obsidian config:

```lua
opts = {
  daily = { format = "YYYY-MM-DD [daily]", folder = "daily", template = "templates/daily" },
  papers = { folder = "literature" },
}
```

## Commands and keymaps

| Command             | Key (with default prefix) | Action                                                                     |
| ------------------- | ------------------------- | -------------------------------------------------------------------------- |
| `:VaultDaily`       | `<leader>vd`              | Open today's daily note, creating it from the template if needed           |
| `:VaultDailyPrev`   | `<leader>vp`              | Go to the previous existing daily note                                     |
| `:VaultDailyNext`   | `<leader>vn`              | Go to the next existing daily note                                         |
| `:VaultFrontmatter` | `<leader>vf`              | Insert a `created` / `tags` YAML block at the top of the buffer            |
| `:VaultTasks[!]`    | `<leader>vt`              | Fuzzy-search open tasks in the whole vault (`!` also lists done tasks)     |
| `:VaultCite`        | `<leader>vc`              | Pick a Zotero entry, insert `[[@citekey]]`, create its paper note if missing |
| `:VaultPaper`       | `<leader>vz`              | Pick a Zotero entry and open its paper note, creating it if missing        |

## Configuration examples

### Change or disable the keymaps

```lua
opts = { prefix = "<localleader>n" } -- <localleader>nd, <localleader>nt, ...
opts = { prefix = false }            -- no keymaps, use the commands only
```

Your own mapping to a single command:

```lua
vim.keymap.set("n", "<leader>td", "<cmd>VaultDaily<cr>", { desc = "Today's note" })
```

Labelling the prefix in [which-key](https://github.com/folke/which-key.nvim):

```lua
{ "<leader>v", group = "vault notes" }
```

### Daily notes

Settings come from `.obsidian/daily-notes.json`:

```json
{
  "format": "YYYY-MM-DD [[daily]]",
  "folder": "daily",
  "template": "templates/daily"
}
```

This gives `daily/2026-10-19 [daily].md`. With no `daily-notes.json` the `daily` options from `setup()` apply
(default: `YYYY-MM-DD.md` in the vault root, empty file).

- Supported format tokens: `YYYY`, `MM`, `DD`, `HH`, `mm`, and `[literal text]`. Other moment.js tokens
  (`ddd`, `MMM`, ...) are not understood.
- The template is `<vault>/<template>.md`. Only `<% tp.date.now("fmt") %>` is expanded; other Templater
  tags are copied as-is.
- `:VaultDailyPrev` / `:VaultDailyNext` move between notes that exist, ordered by the date in the filename.
  From a non-daily buffer they move relative to today.

Example template (`templates/daily.md`):

```markdown
---
created: <% tp.date.now("YYYY.MM.DD HH:mm") %>
tags: daily
---

# TODO

- [ ]
```

### Tasks

`:VaultTasks` matches lines like `- [ ] text` (also `*` and `+` bullets, indented sub-tasks) in every `.md`
file in the vault, and opens a snacks picker. Type to fuzzy-filter, `<CR>` jumps to the line. `:VaultTasks!`
also matches done tasks (`- [x]`).

The picker is `Snacks.picker.grep`, so your snacks `picker` options (layout, keymaps) apply.

### Front-matter

`:VaultFrontmatter` prepends this to the buffer (and refuses if the file already starts with `---`):

```yaml
---
created: 2026.10.19 10:55
tags: []
---
```

### Zotero

There are two sources, tried in this order:

1. **Zotero database** (default): `zotero_db`, read directly with `sqlite3`.
2. **CSL-JSON export**: the path in the obsidian-citation-plugin settings
   (`citationExportPath` in `.obsidian/plugins/obsidian-citation-plugin/data.json`), default
   `assets/bib/zotero.json`.

```lua
-- default: read the live database
opts = { zotero_db = "~/Zotero/zotero.sqlite" }

-- non-standard Zotero data directory
opts = { zotero_db = "/Volumes/data/Zotero/zotero.sqlite" }

-- use only the CSL-JSON file exported from Zotero / Better BibTeX
opts = { zotero_db = false }
```

In the Zotero picker, type to fuzzy-filter and `<CR>` inserts the citation (`:VaultCite`) or opens the note
(`:VaultPaper`). `<C-t>` opens the highlighted item in the Zotero app and leaves the picker open, so you can
keep browsing. This overrides snacks' default `<C-t>` (open in tab) inside this picker only.

The link is `zotero://select/library/items/<itemKey>` when reading the database. With the CSL-JSON fallback
there is no item key, so it uses `zotero://select/items/@<citekey>`, which needs Better BibTeX installed in Zotero.

Notes on the database mode:

- The database is opened read-only through a `file:...?mode=ro` URI, so it is safe while Zotero is open
  (Zotero uses WAL mode) and new items appear with no re-export. Nothing is copied or written.
- If Zotero is configured with `extensions.zotero.dbLockExclusive = true` the read fails with
  "database is locked". Turn that pref off, or set `zotero_db = false` and use the CSL-JSON export.
- Citation keys come from Zotero's built-in `citationKey` field (set by Zotero 7 or Better BibTeX).
  Items without one are skipped.
- Only the `author` creator role is read.

Where paper notes go: `literatureNoteFolder` from the citation plugin's `data.json` (default `papers`),
named `@<citekey>.md`. A new note looks like this:

```markdown
---
title: "Lagrangian Neural Networks"
authors:
  - "Miles Cranmer"
published: "ICLR"
year: 2020
key: cranmerLagrangianNeuralNetworks2020
zotero: zotero://select/items/@cranmerLagrangianNeuralNetworks2020
url: https://...
tags:
  - paper
---

# Lagrangian Neural Networks

_Miles Cranmer_
ICLR

> [!abstract]
> ...
```

Existing notes are never overwritten.

### Pairing with an LSP

[markdown-oxide](https://github.com/Feel-ix-343/markdown-oxide) covers wiki-link/tag completion,
go-to-definition and backlinks (the `[[@citekey]]` that `:VaultCite` inserts jumps to the paper note);
vault.nvim covers Zotero, tasks, front-matter and daily notes.

```lua
vim.lsp.enable("markdown_oxide") -- config shipped by nvim-lspconfig
```

If you also want oxide's own `:LspToday` to match your daily notes, put this in `.moxide.toml`
(strftime format, unlike the moment.js one above):

```toml
dailynote = "%Y-%m-%d [daily]"
daily_notes_folder = "daily"
```

## Development

```sh
nvim -l tests/spec.lua   # date parsing, note rendering, and (if present) your real Zotero db
```
