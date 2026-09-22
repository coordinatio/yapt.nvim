# yapt.nvim

**An AI coding assistant-oriented popup terminal for Neovim.** Toggle, manage, and interact with multiple terminal sessions without leaving your editor. Designed for CLI AI agents (opencode, Cursor, Claude, Aider, and more) and any terminal application.

YAPT gives you a quake-style popup terminal workflow: summon a terminal on demand, switch between sessions, send file contents, copy output — all with keyboard shortcuts. Built for developers who run AI coding assistants alongside their editor and want seamless switching between code and CLI.

---

## Features

- Toggle a terminal in split (``<A-\`>``) or fullscreen (`<A-=>`) mode
- Manage multiple terminal sessions simultaneously — switch, rename, create
- Fuzzy finder with live preview of terminal output (Telescope integration)
- Prompt history — create markdown prompt files, browse with Telescope, send to terminal
- Preset prompts — reusable `.md` files from Neovim config and the project, picked in Telescope
- Passthrough mode — send keys directly to TUI apps running inside the terminal
- Copy `@file` and `@file:start-end` links for use in AI prompts
- Keyboard-driven — operate terminals without leaving the home row
- Full terminal mode keybindings for managing sessions from within a terminal
- Persistent sessions — hide/show without restarting the CLI process
- Multi-command picker — configure several CLI commands and pick one on launch
- Pure Lua, built for Neovim >= 0.11.0

---

## Requirements

- Neovim >= 0.11.0
- Any CLI application (opencode, cursor CLI, claude, aider, etc.)
- Telescope (optional, for fuzzy picker, prompt history, and preset prompts)

---

## Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "coordinatio/yapt.nvim",
  config = function()
    require("yapt").setup()
  end,
}
```

### Using [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  "coordinatio/yapt.nvim",
  config = function()
    require("yapt").setup()
  end,
}
```

### Using [vim-plug](https://github.com/junegunn/vim-plug)

```vim
Plug 'coordinatio/yapt.nvim'

lua << EOF
require("yapt").setup()
EOF
```

---

## Usage

### Quick Start

1. **Open/Toggle Terminal**: Press ``<A-\`>`` in normal mode
   - First time: Creates a terminal with your default command
   - After that: Toggles (show/hide) the last active session
2. **Fullscreen Toggle**: Press `<A-=>` in normal mode
   - Shows terminal in the current window (no split — ideal for small screens)
   - Press again to switch back to your file
3. **Create New Terminal**: Press `<leader>an` to create an additional session (sends the current file if it has content)
4. **Create New Fullscreen Terminal**: Press `<leader>aN` to create in fullscreen mode
5. **Send File to Fullscreen**: Press `<leader>aE` to send current file contents to the terminal and force fullscreen
6. **Switch Terminals**: Press `<F6>` to open a fuzzy picker with live preview
7. **Rename Terminal**: Press `<leader>ar` to rename the current terminal

### Multi-Terminal Management

Work with multiple terminal sessions for different tasks:

#### From Normal Mode

| Keybinding | Action |
|------------|--------|
| ``<A-\`>`` | Smart toggle — create first terminal or show last active (split) |
| `<A-=>` | Fullscreen toggle — show terminal fullscreen or switch back to file |
| `<leader>an` | Create new terminal; send current file if non-empty |
| `<leader>aN` | Create new terminal fullscreen; send current file if non-empty |
| `<F6>` | Select terminal from fuzzy picker (with live preview) |
| `<leader>ar` | Rename current terminal |
| `<leader>ah` | Create new prompt file in `.nvim-yapt/history/` (timestamp in filename) |
| `<leader>ae` | Send current file contents to terminal |
| `<leader>aE` | Send current file contents to terminal (force fullscreen) |
| `<leader>aH` | Open prompt history directory in Telescope |
| `<leader>al` | Open or switch to last prompt file from history |
| `<leader>ap` | Open preset prompts (Telescope, or vim.ui.select) |
| `<leader>ac` | Copy `@file` link to clipboard (paste into CLI prompt) |
| `<leader>i` | Send next key directly to TUI app in terminal |

#### From Visual Mode

| Keybinding | Action |
|------------|--------|
| `<leader>ac` | Copy `@file:start-end` link to clipboard (paste into CLI prompt) |

#### From Terminal Mode

When inside a terminal, manage sessions without leaving:

| Keybinding | Action |
|------------|--------|
| ``<A-\`>`` | Exit terminal mode / hide terminal window |
| `<A-w>` | Move focus to another window |
| `<A-=>` | Toggle fullscreen mode / exit terminal |
| `<F7>` | Create new terminal |
| `<F6>` | Select terminal from fuzzy picker |
| `<F2>` | Rename current terminal |
| `<F12>` | Open or switch to last prompt file from history |
| `<leader>i` | Send next key directly to TUI app in terminal |

`<A-w>` moves focus to the previous window in this tab, or else the next non-floating window, skipping windows with `focusable == false`, and leaves the terminal visible. It does nothing when this is the only usable window. Job mode, or normal mode on the last line, keeps autoscroll; normal mode above the last line keeps the scrollback snapshot.

### Passthrough

When a TUI application (e.g. a text editor, file manager, or pager) runs inside the terminal, Neovim's normal-mode keybindings intercept keys. The passthrough key lets you send keys directly to the TUI app.

**Single-key passthrough** (`<leader>i` by default):
1. Navigate to the terminal window in normal mode
2. Press `<leader>i`, then press any key — it is sent directly to the TUI
3. You return to normal mode immediately

### Prompt History Workflow

Create a markdown file for your CLI task and send it in one go:

1. **Create prompt file**: `:PTPrompt` or `<leader>ah`
   - Creates `${CWD}/.nvim-yapt/history/` if needed
   - Opens a new file named like `2025-02-04_14-30-45.md` (date and time to the second)
2. **Write your prompt** in the opened buffer (what you want the CLI to do).
3. **Send to terminal**: `:PTSend` / `<leader>ae` (reuse last session), or `:PTNew` / `<leader>an` (always a new session)
   - Saves the buffer if modified
   - Shows/creates the terminal and sends the current buffer contents directly
   - If current buffer is a prompt file created by `<leader>ah`, it is closed after successful send
   - If current buffer is an unnamed/new file (e.g. a fresh `:enew` buffer) with content, a prompt-history file is created automatically (timestamped, in `.nvim-yapt/history/`), the content is saved into it, and it is then treated like a prompt file — closed after a successful send. An empty buffer (named or unnamed) aborts with a warning for `:PTSend` / `<leader>ae`; `:PTNew` / `<leader>an` still creates a terminal without sending.
   - If no file buffers remain, opens an empty buffer
   - Fullscreen variants: `:PTSendFullscreen` / `<leader>aE`, `:PTNewFullscreen` / `<leader>aN`

Prompt-file buffers are automatically saved to disk when you leave them (switch buffer, close window, open the picker, etc.), so they appear in `:PTHistory` and `:PTLast` without a manual `:write`. Disable with `history.autosave = false`.

**Additional history actions:**

- **Browse history in Telescope**: `:PTHistory` or `<leader>aH`
- **Open last prompt**: `:PTLast` or `<leader>al`

### Preset Prompts

Keep reusable prompts as markdown files and clone them into history when you need them (the library file is never overwritten).

**Where to put files:**

| Library | Default path |
|---------|----------------|
| Global | `~/.config/nvim/yapt/prompts/` (`stdpath("config")/yapt/prompts`) |
| Project | `${CWD}/.nvim-yapt/prompts/` |

Nested folders work: `review/pr.md` shows as `review/pr.md`. Project entries are listed first and tagged `project` or `global`. Same name in both libraries appears twice.

If you gitignore `.nvim-yapt/*` (recommended for draft history), allow the project library so teammates can share prompts:

```
.nvim-yapt/*
!.nvim-yapt/prompts/
!.nvim-yapt/prompts/**
```

Or set `prompts.project_dir` to a committed path.

**Pick a preset:** `:PTPresets` or `<leader>ap`

| Key | Action |
|-----|--------|
| Enter | Clone into a **new** prompt-history file and open **that copy** (the library file is never opened). From a non-protected view (ordinary file, Reader, help, oil, …) this **replaces the current buffer**. From a protected window it opens a split: float, terminal, cmdwin, quickfix, prompt, preview, or any window with `winfixwidth`/`winfixheight`/`winfixbuf` (a pinned file, not only a sidebar). Edit, then `<leader>ae` to send |
| `<C-x>` / `<C-v>` / `<C-t>` | Same clone, opened in a horizontal split / vertical split / new tab |
| `<C-s>` | **Send immediately** to the terminal (shown / force-insert) and keep a history copy. The source buffer is not closed or replaced. |
| `<C-y>` | **Insert** the preset at the cursor in the current file buffer |

`<C-y>` is used instead of `<C-i>` because `<C-i>` is Tab in Neovim and would steal Tab in the picker. Without Telescope, `vim.ui.select` is used with Enter-only (clone then open the copy the same way Enter does).

If both directories are empty, YAPT notifies the paths to add files to (it does not create them).

---

## Commands

### Terminal Management

| Command | Action |
|---------|--------|
| `:PTT` | Toggle terminal (split mode) |
| `:PTFullscreen` | Toggle terminal (fullscreen mode) |
| `:PTNew [name]` | Create new terminal (optional name); send current file if non-empty |
| `:PTNewFullscreen [name]` | Create new terminal fullscreen (optional name); send current file if non-empty |
| `:PTSelect` | Open terminal picker |
| `:PTRename [name]` | Rename active terminal (interactive if no argument) |
| `:PTList` | List all terminals with status |

### Prompt History and Presets

| Command | Action |
|---------|--------|
| `:PTPrompt` | Create new prompt file in `.nvim-yapt/history/` |
| `:PTSend` | Send current file contents to active terminal |
| `:PTSendFullscreen` | Send current file contents to active terminal (force fullscreen) |
| `:PTHistory` | Open prompt history directory in Telescope |
| `:PTLast` | Open or switch to last prompt file from history |
| `:PTPresets` | Open preset prompts (Telescope, or vim.ui.select) |

### Utilities

| Command | Action |
|---------|--------|
| `:PTCopyLink [range]` | Copy `@file:start-end` link to clipboard; use range (e.g. `:10,20PTCopyLink`) or current line |
| `:PTSay <text>` | Send arbitrary text to active terminal |
| `:PTVersion` | Display plugin version |

To close a terminal, type `exit` or press `Ctrl+D`.

---

## Configuration

### Default Configuration

```lua
require("yapt").setup({
  keybindings = {
    toggle                = "<A-`>",      -- Toggle terminal in split
    toggle_fullscreen      = "<A-=>",     -- Toggle terminal fullscreen
    new                    = "<leader>an", -- Create new terminal; send file if non-empty
    new_fullscreen         = "<leader>aN", -- Create new terminal fullscreen; send file if non-empty
    select                 = "<F6>",       -- Select terminal (fuzzy picker)
    rename                 = "<leader>ar", -- Rename current terminal
    prompt_new             = "<leader>ah", -- Create new prompt file
    prompt_send            = "<leader>ae", -- Send current file to terminal
    prompt_send_fullscreen = "<leader>aE", -- Send current file to terminal (force fullscreen)
    prompt_history_telescope = "<leader>aH", -- Open prompt history in Telescope
    prompt_last            = "<leader>al", -- Open or switch to last prompt buffer
    prompt_presets         = "<leader>ap", -- Open preset prompts (Telescope, or vim.ui.select)
    copy_link              = "<leader>ac", -- Copy @file or @file:start-end link
  },

  history = {
    dir = ".nvim-yapt/history",  -- Relative to CWD
    autosave = true,           -- Save prompt-file buffers to disk when left
  },

  prompts = {
    -- nil → stdpath("config")/yapt/prompts (typically ~/.config/nvim/yapt/prompts)
    -- Empty string disables that source.
    dir = nil,
    project_dir = ".nvim-yapt/prompts", -- Relative to CWD
  },

  terminal = {
    default_name = "Term",     -- Name prefix
    auto_number  = true,       -- Auto-append numbers (Term 1, Term 2, etc.)
    -- Strip trailing spaces from cell-grid padding on yank (also removes intentional ones)
    trim_yank_trailing_whitespace = true,
  },

  split = {
    position = "right",  -- "right", "left", "top", "bottom"
    size     = 0.5,      -- 50% of editor width/height
  },

  -- CLI command to run (string or table)
  -- When a table is provided, a Telescope picker appears when creating
  -- a new terminal, letting you choose which command to launch.
  -- Supports plain strings, { "Label", "command" }, or { label=.., command=.. }.
  command = "opencode",
  -- command = { "opencode", "cursor agent", "claude", "aider" },
  -- command = {
  --   { label = "OpenCode",     command = "opencode" },
  --   { label = "Cursor Agent", command = "cursor agent" },
  -- },

  term_opts = {
    on_open  = nil,
    on_close = nil,
  },

  terminal_keybindings = {
    hide             = "<A-`>",
    unfocus          = "<A-w>",
    toggle_fullscreen = "<A-=>",
    new              = "<F7>",
    rename           = "<F2>",
    select           = "<F6>",
    prompt_last      = "<F12>",
    passthrough      = "<leader>i",
  },
})
```

### Configuration Examples

#### Custom Keybindings

```lua
require("yapt").setup({
  keybindings = {
    toggle = "<C-a>",
    new    = "<C-n>",
    select = "<C-s>",
    rename = "<leader>rn",
  },
})
```

#### Multiple Commands (Command Picker)

```lua
require("yapt").setup({
  command = { "opencode", "cursor agent", "claude", "aider" },
})
```

When multiple commands are configured, a Telescope picker appears every time a new terminal is created.

#### Command Labels

For a clearer picker experience, use labeled commands. The label is shown in the Telescope picker while the command string is what actually runs:

```lua
require("yapt").setup({
  command = {
    { label = "OpenCode",      command = "opencode" },
    { label = "Cursor Agent",  command = "cursor agent" },
    { label = "Claude Code",   command = "claude" },
    { label = "Aider",         command = "aider" },
  },
})
```

You can also use the short form `{ "Label", "command" }`:

```lua
command = {
  { "OpenCode", "opencode" },
  { "Claude Code", "claude" },
}
```

#### Left Split with 40% Width

```lua
require("yapt").setup({
  split = {
    position = "left",
    size     = 0.4,
  },
})
```

#### Custom Terminal Names

```lua
require("yapt").setup({
  terminal = {
    default_name = "Session",
    auto_number  = true,  -- "Session 1", "Session 2", etc.
  },
})
```

#### Setting a keybinding to empty disables it

```lua
require("yapt").setup({
  keybindings = {
    copy_link = "",  -- disable copy link
  },
})
```

---

## Advanced Usage

### Programmatic Access

```lua
local yapt = require("yapt")

-- Plugin version
print("Version: " .. yapt.version)

-- Toggle terminal
yapt.normal_mode_handler()

-- Create new terminal (sends current file if non-empty)
yapt.new_terminal_handler()

-- Send text to active terminal
yapt.terminal.send_text("@myfile.lua\nExplain this code")

-- Check if terminal is running
local terminal_id = yapt.tabs.get_active()
if yapt.terminal.is_running(terminal_id) then
  print("Terminal is running")
end

-- List all terminals
local terminals = yapt.tabs.list_terminals()
for _, term in ipairs(terminals) do
  print(string.format("%s: %s", term.id, term.name))
end

-- Get terminal state (for debugging)
local state = yapt.tabs.get_state()
print(vim.inspect(state))
```

### Multi-Terminal API

```lua
local tabs = require("yapt.tabs")

local active_id = tabs.get_active()
local term = tabs.get_terminal(active_id)
print("Name: " .. term.name)
print("Created: " .. term.created_at)

tabs.rename_terminal(active_id, "New Name")
tabs.delete_terminal(active_id)

if tabs.has_terminals() then
  print("Terminals count: " .. tabs.count())
end
```

---

## Tips

### Organizing Terminals

Use descriptive names to organize by task:
- **"Backend API"** — for backend code questions
- **"Frontend UI"** — for UI/UX implementation
- **"Debug Session"** — for troubleshooting
- **"Code Review"** — for reviewing pull requests
- **"Documentation"** — for writing docs

### Efficient Workflows

1. **Keep sessions focused**: Create separate terminals for different contexts
2. **Use terminal mode shortcuts**: Stay in terminal mode with `<F7>`, `<F6>`, `<F2>` for faster navigation
3. **Leverage the preview**: Use `<F6>` to preview conversations before switching
4. **Name early**: Rename terminals as soon as you know their purpose with `<F2>`

### Telescope Integration

For the best experience, install [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim). With Telescope you get:
- **Terminal picker** (`<F6>`): live preview, fuzzy search by name, rename with `<C-r>`
- **Prompt history** (`<leader>aH`): browse `.nvim-yapt/history/` with wrap preview
- **Preset prompts** (`<leader>ap`): global + project libraries, wrap preview, `<C-s>` send, `<C-y>` insert

Without Telescope, terminal and command pickers fall back to `vim.ui.select`. The history command shows a warning if Telescope is not available. Preset prompts fall back to `vim.ui.select` (Enter clones into history; extra actions require Telescope).

---

## Troubleshooting

### Terminal doesn't open

- Ensure the CLI application is installed and in your PATH
- Try running the command manually in your shell to verify it works
- Check for errors with `:messages`

### Keybinding doesn't work

- Make sure `<leader>` is set in your config (e.g., `vim.g.mapleader = " "`)
- Check for conflicting keybindings with ``:verbose map <A-\`>``

### Visual selection not working

- Ensure you're pressing the toggle key while still in visual mode
- The selection is sent after the terminal opens/shows

### "Current buffer is empty — nothing to send"

- Shown when running `:PTSend` / `<leader>ae` (or fullscreen variants) on an empty buffer — named or unnamed. Type something first.
- Unnamed buffers *with* content no longer need to be saved manually — a history file is created for them automatically.

---

## Related Projects

- [opencode](https://github.com/anomalyco/opencode) — AI coding CLI tool
- [toggleterm.nvim](https://github.com/akinsho/toggleterm.nvim) — Terminal management for Neovim
- [vim-floaterm](https://github.com/voldikss/vim-floaterm) — Floating terminal plugin

---

## Fork Acknowledgment

This plugin started as a fork of [felixcuello/neovim-cursor](https://github.com/felixcuello/neovim-cursor), a simple integration of the Cursor AI agent CLI into Neovim. Since then, yapt.nvim has grown into a standalone, AI-coding-assistant-oriented terminal workflow solution with multi-session management, prompt history, passthrough mode, fullscreen support, and more — significantly diverging from its origins.

---

## License

GPLv3
