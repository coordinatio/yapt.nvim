-- Temporary artefact paths for yapt.nvim
--
-- Prompt authors insert a path under ${CWD}/.nvim-yapt/artefacts/ so an
-- agent can write a throwaway file (a report, a dump) outside git.
-- The file itself is not created here; only the directory is.
--
-- Browse existing files with the same Telescope layout as prompt history.

local util = require("yapt.util")

local M = {}

local DEFAULT_DIR = ".nvim-yapt/artefacts"
-- Dot plus this many ASCII letters/digits still counts as a typed extension.
local MAX_EXT_LEN = 10

local function configured_dir(cfg)
  local dir = cfg and cfg.artefacts and cfg.artefacts.dir
  if type(dir) ~= "string" or dir == "" then
    dir = DEFAULT_DIR
  end
  return dir:gsub("/+$", "")
end

-- Absolute directory used for mkdir and collision checks.
local function artefacts_dir_path(cfg)
  local dir = configured_dir(cfg)
  if dir:match("^/") then
    return dir
  end
  return vim.fn.getcwd() .. "/" .. dir
end

-- @return string|nil directory, or nil when mkdir fails
local function ensure_artefacts_dir(config)
  local dir = artefacts_dir_path(config)
  pcall(vim.fn.mkdir, dir, "p")
  if vim.fn.isdirectory(dir) ~= 1 then
    util.notify("Failed to create artefacts directory: " .. dir, vim.log.levels.ERROR)
    return nil
  end
  return dir
end

-- One filename component: whitespace to "-", drop path/control characters,
-- keep letters (including non-ASCII) and case. A short ASCII extension is
-- kept; otherwise ".md" is added. Nil when nothing usable remains.
-- @param raw string
-- @return string|nil
local function normalize_name(raw)
  if type(raw) ~= "string" then
    return nil
  end
  local name = vim.trim(raw)
  if name == "" then
    return nil
  end

  name = name:gsub("%s+", "-")
  name = name:gsub("[%z%c/\\:*?\"<>|]", "")
  name = name:gsub("%-+", "-")
  name = name:gsub("^[-.]+", ""):gsub("[-.]+$", "")
  if name == "" then
    return nil
  end

  local stem, ext = name:match("^(.*)(%.[A-Za-z0-9]+)$")
  if stem and stem ~= "" and ext and (#ext - 1) <= MAX_EXT_LEN then
    stem = stem:gsub("^[-.]+", ""):gsub("[-.]+$", "")
    stem = stem:gsub("%-+", "-"):gsub("^-+", ""):gsub("-+$", "")
  else
    stem = name
    ext = ".md"
  end

  if stem == "" then
    return nil
  end
  return stem .. ext
end

-- YYYY-MM-DD_HH-MM-SS_<normalized>, with _1, _2, ... before the extension
-- when that path is already on disk.
-- @param dir string absolute artefacts directory
-- @param normalized string filename from normalize_name
-- @return string basename
local function unique_artefact_filename(dir, normalized)
  local stem, ext = normalized:match("^(.*)(%.[^%.]+)$")
  if not stem or stem == "" then
    stem = normalized
    ext = ""
  end
  local stamp = os.date("%Y-%m-%d_%H-%M-%S")
  local function named(suffix)
    return stamp .. "_" .. stem .. suffix .. ext
  end
  local filename = named("")
  local n = 1
  while vim.uv.fs_stat(dir .. "/" .. filename) ~= nil do
    filename = named("_" .. n)
    n = n + 1
  end
  return filename
end

-- Relative (or absolute, when artefacts.dir is absolute) path to insert.
-- Creates the directory. Does not create the file.
-- @param raw_name string
-- @return string|nil
local function build_artefact_link(config, raw_name)
  local normalized = normalize_name(raw_name)
  if not normalized then
    util.notify("Artefact name is not a valid filename", vim.log.levels.WARN)
    return nil
  end
  local dir = ensure_artefacts_dir(config)
  if not dir then
    return nil
  end
  local filename = unique_artefact_filename(dir, normalized)
  return configured_dir(config) .. "/" .. filename
end

-- @param loc table resolve_file_location()
-- @return boolean
local function can_insert(loc)
  local source_buf = loc and loc.source_bufnr
  if not source_buf or not vim.api.nvim_buf_is_valid(source_buf) then
    util.notify("Cannot insert: original buffer is gone", vim.log.levels.WARN)
    return false
  end
  if vim.bo[source_buf].buftype ~= "" then
    util.notify("Cannot insert into a non-file buffer", vim.log.levels.WARN)
    return false
  end
  if not vim.bo[source_buf].modifiable then
    util.notify("Cannot insert: buffer is not modifiable", vim.log.levels.WARN)
    return false
  end
  return true
end

-- Snapshot Source line/column before vim.ui.input. Reader/Float cursors are
-- mapped the same way as preset insert.
-- @return table loc, integer[] cursor {lnum, col}, integer winid
local function capture_insert_target()
  local loc = util.resolve_file_location()
  local winid = vim.api.nvim_get_current_win()
  local cursor = vim.api.nvim_win_get_cursor(winid)
  local view_buf = loc.view_bufnr
  if view_buf and view_buf ~= loc.source_bufnr then
    local mapped = util.map_view_cursor_to_source(view_buf, winid)
    if mapped then
      cursor = { mapped.lnum, mapped.col }
    else
      cursor = { util.map_line_to_source(view_buf, cursor[1]) or cursor[1], 0 }
    end
  end
  return loc, cursor, winid
end

-- Insert `text` into the Source file buffer at the captured cursor.
-- @return boolean
local function insert_text_at_cursor(text, loc, cursor, winid)
  loc = loc or util.resolve_file_location()
  if not can_insert(loc) then
    return false
  end

  local source_buf = loc.source_bufnr
  local view_buf = loc.view_bufnr
  local row, col
  if cursor then
    row, col = cursor[1], cursor[2]
  else
    local last = vim.api.nvim_buf_line_count(source_buf)
    local last_line = vim.api.nvim_buf_get_lines(source_buf, last - 1, last, false)[1] or ""
    row, col = last, #last_line
  end

  local last = vim.api.nvim_buf_line_count(source_buf)
  row = math.max(1, math.min(row, last))
  local line = vim.api.nvim_buf_get_lines(source_buf, row - 1, row, false)[1] or ""
  col = util.clamp_col_to_char_boundary(line, col)

  local ok, err = pcall(vim.api.nvim_buf_set_text, source_buf, row - 1, col, row - 1, col, { text })
  if not ok then
    util.notify("Failed to insert artefact path: " .. tostring(err), vim.log.levels.ERROR)
    return false
  end

  if view_buf then
    util.close_float_view_if_needed(view_buf)
  end

  local origin = winid
  if origin
    and util.win_in_current_tab(origin)
    and util.is_non_terminal_window(origin)
    and vim.api.nvim_win_get_buf(origin) ~= source_buf
  then
    pcall(vim.api.nvim_win_set_buf, origin, source_buf)
  end

  local new_col = col + #text
  local win
  if origin
    and util.win_in_current_tab(origin)
    and vim.api.nvim_win_get_buf(origin) == source_buf
  then
    win = origin
  else
    win = util.window_showing_buffer(source_buf)
  end
  if win then
    pcall(vim.api.nvim_set_current_win, win)
    pcall(vim.api.nvim_win_set_cursor, win, { row, new_col })
  end
  return true
end

-- Insert a timestamped artefact path at the cursor.
-- `name` nil or blank opens vim.ui.input. Cancel and blank input do nothing.
-- @param name string|nil
-- @return string|nil inserted path
function M.insert_artefact_link(config, name)
  config = config or {}
  local loc, cursor, winid = capture_insert_target()
  if not can_insert(loc) then
    return nil
  end

  local function apply(raw)
    if not vim.api.nvim_buf_is_valid(loc.source_bufnr) then
      util.notify("Cannot insert: original buffer is gone", vim.log.levels.WARN)
      return nil
    end
    local link = build_artefact_link(config, raw)
    if not link then
      return nil
    end
    if not insert_text_at_cursor(link, loc, cursor, winid) then
      return nil
    end
    return link
  end

  if type(name) == "string" and vim.trim(name) ~= "" then
    return apply(name)
  end

  vim.ui.input({
    prompt = "Artefact name: ",
  }, function(input)
    if not input or vim.trim(input) == "" then
      return
    end
    vim.schedule(function()
      apply(input)
    end)
  end)
  return nil
end

-- Timestamp prefix YYYY-MM-DD_HH-MM-SS, optional collision suffix ignored.
-- @return number|nil unix time
local function parse_timestamp_from_filename(filename)
  local y, mo, d, h, mi, s = filename:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)_(%d%d)%-(%d%d)%-(%d%d)")
  if not y then
    return nil
  end
  local ts = os.time({
    year = tonumber(y),
    month = tonumber(mo),
    day = tonumber(d),
    hour = tonumber(h),
    min = tonumber(mi),
    sec = tonumber(s),
  })
  if type(ts) ~= "number" then
    return nil
  end
  return ts
end

local function is_listed_artefact(name, fullpath)
  if name == "" or name:sub(1, 1) == "." then
    return false
  end
  if vim.fn.isdirectory(fullpath) == 1 then
    return false
  end
  local kind = vim.fn.getftype(fullpath)
  return kind == "file" or kind == "link"
end

-- Newest first. Filename timestamp, then mtime, then name.
local function list_artefact_files_sorted(config)
  config = config or {}
  local dir = artefacts_dir_path(config)
  if vim.fn.isdirectory(dir) ~= 1 then
    return {}, dir
  end

  local entries = {}
  for _, name in ipairs(vim.fn.readdir(dir)) do
    local fullpath = dir .. "/" .. name
    if is_listed_artefact(name, fullpath) then
      local ts = parse_timestamp_from_filename(name)
      if not ts then
        local ft = vim.fn.getftime(fullpath)
        if type(ft) == "number" and ft >= 0 then
          ts = ft
        else
          ts = 0
        end
      end
      table.insert(entries, {
        name = name,
        path = fullpath,
        ts = ts,
      })
    end
  end

  table.sort(entries, function(a, b)
    if a.ts ~= b.ts then
      return a.ts > b.ts
    end
    return a.name > b.name
  end)

  return entries, dir
end

-- Open the artefacts directory in Telescope. Warns when Telescope is absent.
function M.open_artefacts_in_telescope(config)
  local ok = pcall(require, "telescope")
  if not ok then
    util.notify("telescope.nvim is required for PTArtefacts", vim.log.levels.WARN)
    return
  end

  local entries, dir = list_artefact_files_sorted(config)
  if vim.fn.isdirectory(dir) ~= 1 then
    vim.fn.mkdir(dir, "p")
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local make_entry = require("telescope.make_entry")
  local previewers = require("telescope.previewers")
  local sorters = require("telescope.sorters")

  local results = {}
  for _, e in ipairs(entries) do
    table.insert(results, e.name)
  end

  local entry_maker = make_entry.gen_from_file({
    cwd = dir,
  })

  local base_sorter = conf.file_sorter({})
  local chronological_sorter = sorters.Sorter:new({
    discard = base_sorter.discard,
    scoring_function = function(_, prompt, line, entry, cb_add, cb_filter)
      if not prompt or prompt == "" then
        return 1
      end
      return base_sorter:scoring_function(prompt, line, entry, cb_add, cb_filter)
    end,
    highlighter = function(_, prompt, display)
      if base_sorter.highlighter and prompt and prompt ~= "" then
        return base_sorter:highlighter(prompt, display)
      end
      return {}
    end,
  })

  local artefact_previewer = previewers.new_buffer_previewer({
    title = "Artefact preview",
    define_preview = function(self, entry, _status)
      local path = entry.path or entry.value
      if not path or path == "" then
        vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, { "No file to preview" })
        return
      end

      previewers.buffer_previewer_maker(path, self.state.bufnr, { winid = self.state.winid })
      util.apply_wrap(self.state.winid)
    end,
  })

  pickers.new({}, {
    prompt_title = "Artefacts",
    finder = finders.new_table({
      results = results,
      entry_maker = entry_maker,
    }),
    sorter = chronological_sorter,
    tiebreak = function()
      return false
    end,
    previewer = artefact_previewer,
    attach_mappings = function(prompt_bufnr, _map)
      actions.select_default:replace(function()
        actions.close(prompt_bufnr)
        local selection = action_state.get_selected_entry()
        if selection then
          local path = selection.path or selection.value
          if path and path ~= "" then
            vim.cmd("edit " .. vim.fn.fnameescape(path))
          end
        end
      end)
      return true
    end,
  }):find()
end

return M
