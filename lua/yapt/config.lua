-- Default configuration for yapt.nvim plugin
local M = {}

local util = require("yapt.util")

M.defaults = {
  -- Keybinding for toggling terminal (backward compatibility)
  keybinding = "<A-`>",

  -- Multi-terminal keybindings
  keybindings = {
    toggle = "<A-`>",                -- Toggle terminal window in split (show last active)
    toggle_fullscreen = "<A-=>",     -- Toggle terminal window fullscreen (show last active)
    new = "<leader>an",              -- Create new terminal; send current file if non-empty
    new_fullscreen = "<leader>aN",   -- Create new terminal fullscreen; send current file if non-empty
    select = "<F6>",                 -- Select terminal (fuzzy picker)
    rename = "<leader>ar",           -- Rename current terminal
    prompt_new = "<leader>ah",       -- Create new prompt file in .nvim-yapt/history
    prompt_send = "<leader>ae",      -- Send current file contents to terminal
    prompt_send_fullscreen = "<leader>aE",  -- Send current file contents to terminal (force fullscreen)
    prompt_history_telescope = "<leader>aH",  -- Open prompt history dir in Telescope
    prompt_last = "<leader>al",      -- Open or switch to last prompt buffer
    prompt_presets = "<leader>ap",   -- Open preset prompts (Telescope, or vim.ui.select)
    copy_link = "<leader>ac",        -- Copy link (normal: @file, visual: @file:start-end) to unnamed register
  },

  -- Prompt history (md files for terminal tasks)
  history = {
    dir = ".nvim-yapt/history",  -- Relative to CWD
    autosave = true,           -- Save prompt-file buffers to disk when left
  },

  -- Preset prompt libraries (reusable .md files cloned into history)
  -- dir nil → resolved in setup() to stdpath("config")/yapt/prompts
  -- Empty string disables that source.
  prompts = {
    dir = nil,                         -- Global library (Neovim config)
    project_dir = ".nvim-yapt/prompts", -- Relative to CWD
  },

  -- Terminal naming configuration
  terminal = {
    default_name = "Term",      -- Default name prefix for terminals
    auto_number = true,          -- Auto-append numbers (Term 1, Term 2, etc.)
    -- Strip trailing spaces from each line when yanking from a yapt terminal.
    -- Targets cell-grid padding (not hard-wrap); also removes intentional trailing spaces.
    trim_yank_trailing_whitespace = true,
  },

  -- Terminal split configuration
  split = {
    position = "right",  -- right, left, top, bottom
    size = 0.5,          -- 50% of editor width/height
  },

  -- CLI command to run (string or array of strings)
  -- When an array is provided, a Telescope picker will appear when creating
  -- a new terminal, letting you choose which command to launch.
  command = "opencode",

  -- Terminal options
  term_opts = {
    on_open = nil,   -- Callback when terminal opens
    on_close = nil,  -- Callback when terminal closes
  },

  -- Terminal mode keybindings (when inside terminal buffer)
  terminal_keybindings = {
    hide = "<A-`>",      -- Hide terminal window (terminal + normal mode in terminal)
    unfocus = "<A-w>",   -- Move focus to another window
    toggle_fullscreen = "<A-=>", -- Toggle fullscreen mode
    new = "<F7>",        -- Create new terminal
    rename = "<F2>",     -- Rename current terminal
    select = "<F6>",     -- Select terminal
    prompt_last = "<F12>", -- Open or switch to last prompt buffer
    passthrough = "<leader>i", -- Send next key to TUI app
    forward_keys = {"<C-M-u>", "<C-M-d>"}, -- Keys forwarded to TUI in normal mode
  },
}

-- Old history directories that should be migrated to the current default.
local legacy_history_dirs = {
  ".nvim-cursor/history",
}

local function migrate_history_dir(target_dir)
  if target_dir:match("^/") then return end

  local cwd = vim.fn.getcwd()
  local target_path = cwd .. "/" .. target_dir

  if vim.fn.isdirectory(target_path) == 1 then return end

  for _, legacy in ipairs(legacy_history_dirs) do
    local legacy_path = cwd .. "/" .. legacy
    if vim.fn.isdirectory(legacy_path) == 1 then
      local parent = vim.fn.fnamemodify(target_path, ":h")
      vim.fn.mkdir(parent, "p")
      local ok = vim.fn.rename(legacy_path, target_path)
      if ok == 0 then
        util.notify(
          "Migrated prompt history from " .. legacy .. " to " .. target_dir,
          vim.log.levels.INFO
        )
      else
        util.notify(
          "Failed to migrate " .. legacy .. " to " .. target_dir,
          vim.log.levels.WARN
        )
      end
      return
    end
  end
end

-- Merge user config with defaults
-- Maintains backward compatibility with old 'keybinding' option.
function M.setup(user_config)
  user_config = user_config or {}

  if not user_config.history then
    migrate_history_dir(M.defaults.history.dir)
  end

  -- Backward compatibility: if old 'keybinding' provided but not 'keybindings', migrate it
  if user_config.keybinding and not user_config.keybindings then
    user_config.keybindings = {
      toggle = user_config.keybinding,
    }
  end

  -- Deepcopy so nested tables are not shared with M.defaults (tbl_deep_extend
  -- reuses them when the user omits a key; setup then writes prompts.dir).
  local cfg = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), user_config)

  -- If the user didn't explicitly set a command, prefer the dedicated CLI binary
  -- when it exists (common packaging: GUI launcher is `cursor`, CLI is `cursor-agent`).
  if user_config.command == nil and vim.fn.executable("cursor-agent") == 1 then
    cfg.command = "cursor-agent"
  end

  -- Default global preset library: ~/.config/nvim/yapt/prompts (or stdpath("config")).
  -- An explicit empty string disables the global source; a relative path is
  -- resolved against the Neovim config directory.
  if not user_config.prompts or user_config.prompts.dir == nil then
    cfg.prompts.dir = vim.fn.stdpath("config") .. "/yapt/prompts"
  elseif cfg.prompts.dir ~= "" then
    local dir = vim.fn.expand(cfg.prompts.dir)
    if vim.fn.isabsolutepath(dir) == 0 then
      dir = vim.fs.joinpath(vim.fn.stdpath("config"), dir)
    end
    cfg.prompts.dir = vim.fs.abspath(dir):gsub("/$", "")
  end

  return cfg
end

function M.resolve_command(command, config)
  if command then return command end
  if type(config.command) == "string" then return config.command end
  if type(config.command) == "table" and #config.command > 0 then return config.command[1] end
  return "opencode"
end

function M.resolve_command_entries(config)
  local cmd = config.command
  if type(cmd) == "string" then
    return { { label = cmd, command = cmd } }
  end
  if type(cmd) == "table" then
    local entries = {}
    for _, entry in ipairs(cmd) do
      if type(entry) == "string" and #entry > 0 then
        table.insert(entries, { label = entry, command = entry })
      elseif type(entry) == "table" then
        local lbl, cmd
        if type(entry.label) == "string" and #entry.label > 0
          and type(entry.command) == "string" and #entry.command > 0 then
          lbl, cmd = entry.label, entry.command
        elseif type(entry[1]) == "string" and #entry[1] > 0
          and type(entry[2]) == "string" and #entry[2] > 0 then
          lbl, cmd = entry[1], entry[2]
        end
        if lbl and cmd then
          table.insert(entries, { label = lbl, command = cmd })
        end
      end
    end
    if #entries > 0 then return entries end
  end
  return { { label = "opencode", command = "opencode" } }
end

return M
