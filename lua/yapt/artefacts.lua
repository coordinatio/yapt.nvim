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
-- A typed extension of this many ASCII letters/digits is kept only when it
-- contains at least one letter.
local MAX_EXT_LEN = 10
local NAME_MAX = 255
-- Room for "_9999" so a truncated stem still fits the longest suffix we try.
local COLLISION_RESERVE = "_9999"
local MAX_COLLISION_SUFFIX = 1000

-- Absolute paths this process has already handed out. The file is not created,
-- so a second insert in the same second must still see the first reservation.
local reserved_paths = {}

-- U+00A0, U+2000–U+200A, U+202F, U+205F, U+3000. Lua character classes are
-- bytes, so each codepoint is substituted on its own.
local unicode_spaces = {}
local function add_unicode_space(cp)
  unicode_spaces[#unicode_spaces + 1] = vim.fn.nr2char(cp)
end
add_unicode_space(0x00A0)
for cp = 0x2000, 0x200A do
  add_unicode_space(cp)
end
add_unicode_space(0x202F)
add_unicode_space(0x205F)
add_unicode_space(0x3000)

local function configured_dir(cfg)
  local dir = cfg and cfg.artefacts and cfg.artefacts.dir
  if type(dir) ~= "string" or dir == "" then
    dir = DEFAULT_DIR
  end
  -- Expand before the absolute check, same as preset directories.
  -- "/" and "///" strip to empty; fall back so we never mkdir or insert at root.
  dir = vim.fn.expand(dir)
  dir = dir:gsub("/+$", "")
  if dir == "" then
    return DEFAULT_DIR
  end
  return dir
end

-- Absolute directory used for mkdir and collision checks.
-- Relative configured_dir stays relative in the inserted text; getcwd() is
-- only applied here.
local function artefacts_dir_path(cfg)
  local dir = configured_dir(cfg)
  if vim.fn.isabsolutepath(dir) == 1 then
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

local function replace_unicode_spaces(name)
  for _, ch in ipairs(unicode_spaces) do
    name = name:gsub(ch, " ")
  end
  return name
end

-- One filename component: whitespace to "-", forbidden characters to "-".
-- Letters (including non-ASCII) and case stay. A short ASCII extension is
-- kept only when it contains a letter; otherwise ".md" is added.
-- Nil when nothing usable remains (caller warns).
-- @param raw string
-- @return string|nil
local function normalize_name(raw)
  if type(raw) ~= "string" then
    return nil
  end
  local name = replace_unicode_spaces(raw)
  name = vim.trim(name)
  if name == "" then
    return nil
  end

  name = name:gsub("%s+", "-")
  name = name:gsub("[%z%c/\\:*?\"<>|]", "-")
  name = name:gsub("%-+", "-")

  -- Extension before stripping leading dots, so ".json" is not rewritten
  -- into a stem of "json".
  local stem, ext = name:match("^(.*)(%.[A-Za-z0-9]+)$")
  local ext_len = ext and (#ext - 1) or 0
  local keep_ext = stem
    and ext
    and ext_len >= 1
    and ext_len <= MAX_EXT_LEN
    and ext:match("[A-Za-z]")
  if not keep_ext then
    stem = name
    ext = ".md"
  end

  -- Stem only: "foo . bar" became "foo-.-bar"; collapse that run.
  -- Leave real dots ("foo.bar" of "foo.bar.md") in place.
  while stem:find("%-%.%-") do
    stem = stem:gsub("%-%.%-", "-")
  end
  stem = stem:gsub("%-+", "-")
  stem = stem:gsub("^[-.]+", ""):gsub("[-.]+$", "")

  if stem == "" then
    return nil
  end
  return stem .. ext
end

local function absolute_path(path)
  return vim.fn.fnamemodify(path, ":p")
end

local function buffer_named(abs)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" and absolute_path(name) == abs then
        return true
      end
    end
  end
  return false
end

-- "taken", "free", or "error". ENOENT is free. Any other lstat failure
-- (ENAMETOOLONG, EACCES, …) is an error so it cannot look like a free name.
-- A successful lstat is taken for every dirent, including a broken symlink.
local function reservation_state(abs)
  if reserved_paths[abs] then
    return "taken"
  end
  local st, err, errname = vim.uv.fs_lstat(abs)
  if st then
    return "taken"
  end
  if errname ~= "ENOENT" then
    return "error", err or errname or "stat failed"
  end
  if buffer_named(abs) then
    return "taken"
  end
  return "free"
end

-- Drop bytes past max_bytes without splitting a UTF-8 sequence.
-- A sequence that ends on max_bytes is kept; one that would run past it is not.
local function truncate_utf8(s, max_bytes)
  if max_bytes <= 0 then
    return ""
  end
  if #s <= max_bytes then
    return s
  end
  local rel = vim.str_utf_start(s, max_bytes)
  if type(rel) ~= "number" then
    return s:sub(1, max_bytes)
  end
  local start_idx = max_bytes + math.min(rel, 0)
  if start_idx < 1 then
    return ""
  end
  local b = s:byte(start_idx)
  local len = 1
  if b >= 0xF0 then
    len = 4
  elseif b >= 0xE0 then
    len = 3
  elseif b >= 0xC0 then
    len = 2
  end
  local end_idx = start_idx + len - 1
  if end_idx > max_bytes then
    end_idx = start_idx - 1
  end
  if end_idx < 1 then
    return ""
  end
  return s:sub(1, end_idx)
end

-- YYYY-MM-DD_HH-MM-SS_<normalized>, with _1, _2, ... before the extension
-- when that absolute path is reserved, already a dirent, or already a buffer name.
-- @param dir string absolute artefacts directory
-- @param normalized string filename from normalize_name
-- @return string|nil basename
-- @return string|nil warning when no name is returned
local function unique_artefact_filename(dir, normalized)
  local stem, ext = normalized:match("^(.*)(%.[^%.]+)$")
  if not stem or stem == "" then
    stem = normalized
    ext = ""
  end
  local stamp = os.date("%Y-%m-%d_%H-%M-%S")
  local fixed = #stamp + 1 + #COLLISION_RESERVE + #ext
  if fixed > NAME_MAX then
    return nil, "Artefact filename is too long"
  end
  stem = truncate_utf8(stem, NAME_MAX - fixed)
  if stem == "" then
    return nil, "Artefact filename is too long"
  end

  local function named(suffix)
    return stamp .. "_" .. stem .. suffix .. ext
  end

  for n = 0, MAX_COLLISION_SUFFIX do
    local filename = named(n == 0 and "" or ("_" .. n))
    local abs = absolute_path(dir .. "/" .. filename)
    local state, err = reservation_state(abs)
    if state == "error" then
      return nil, "Could not check artefact path: " .. tostring(err)
    end
    if state == "free" then
      reserved_paths[abs] = true
      return filename
    end
  end
  return nil, "Could not find a free artefact filename"
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
  local filename, err = unique_artefact_filename(dir, normalized)
  if not filename then
    util.notify(err, vim.log.levels.WARN)
    return nil
  end
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

  -- A Reader/Float view is not the source file. Closing every float that
  -- shows the source would dismiss an unrelated window on a normal edit.
  if view_buf and view_buf ~= source_buf then
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

-- Timestamp prefix YYYY-MM-DD_HH-MM-SS. Impossible dates that os.time would
-- normalize (month 99, 31 Feb, …) are rejected so the caller can use mtime.
-- @return number|nil unix time
local function parse_timestamp_from_filename(filename)
  local y, mo, d, h, mi, s = filename:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)_(%d%d)%-(%d%d)%-(%d%d)")
  if not y then
    return nil
  end
  local year = tonumber(y)
  local month = tonumber(mo)
  local day = tonumber(d)
  local hour = tonumber(h)
  local min = tonumber(mi)
  local sec = tonumber(s)
  if not year or not month or not day or not hour or not min or not sec then
    return nil
  end
  if month < 1 or month > 12 or day < 1 or day > 31 then
    return nil
  end
  if hour > 23 or min > 59 or sec > 59 then
    return nil
  end
  local ok, ts = pcall(os.time, {
    year = year,
    month = month,
    day = day,
    hour = hour,
    min = min,
    sec = sec,
  })
  if not ok or type(ts) ~= "number" then
    return nil
  end
  local round = os.date("*t", ts)
  if type(round) ~= "table"
    or round.year ~= year
    or round.month ~= month
    or round.day ~= day
    or round.hour ~= hour
    or round.min ~= min
    or round.sec ~= sec
  then
    return nil
  end
  return ts
end

-- Collision suffix "_N" immediately before the last extension, else 0.
-- Base is the filename with that "_N" removed, so "_10" and "_2" share a base.
local function collision_base_and_suffix(filename)
  local base, n, ext = filename:match("^(.*)_(%d+)(%.[^%.]+)$")
  if base and n and ext then
    return base .. ext, tonumber(n)
  end
  return filename, 0
end

local function points_at_regular_file(fullpath)
  local st = vim.uv.fs_stat(fullpath)
  return st ~= nil and st.type == "file"
end

-- Regular files, plus symlinks whose target is a regular file.
-- Directories, fifos, sockets, and broken symlinks are omitted so preview
-- cannot block on a fifo.
local function is_listed_artefact(name, fullpath)
  if name == "" or name:sub(1, 1) == "." then
    return false
  end
  local lst = vim.uv.fs_lstat(fullpath)
  if not lst then
    return false
  end
  if lst.type == "file" then
    return true
  end
  if lst.type == "link" then
    return points_at_regular_file(fullpath)
  end
  return false
end

-- Newest first. A filename timestamp that round-trips beats mtime.
-- Equal timestamps: higher collision suffix, then name.
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
      local base, suffix = collision_base_and_suffix(name)
      table.insert(entries, {
        name = name,
        path = fullpath,
        ts = ts,
        base = base,
        suffix = suffix,
      })
    end
  end

  table.sort(entries, function(a, b)
    if a.ts ~= b.ts then
      return a.ts > b.ts
    end
    if a.base == b.base and a.suffix ~= b.suffix then
      return a.suffix > b.suffix
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
    if not ensure_artefacts_dir(config) then
      return
    end
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
