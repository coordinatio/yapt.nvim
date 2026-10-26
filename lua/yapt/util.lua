-- Shared utility helpers for yapt.nvim plugin
--
-- Centralizes small helpers that several modules need (mostly buffer
-- discovery for "what should I show after I stole this window?" logic).
local M = {}

-- Default title shown in the notification header (e.g. nvim-notify).
local DEFAULT_TITLE = "yapt"

-- Thin wrapper around `vim.notify` that injects a default `title` so the
-- plugin name appears in the notification header (nvim-notify). Any extra
-- opts (e.g. `id`, `timeout`) are merged on top of the defaults, and the
-- caller's table is not mutated. Pass `opts.title = ""` to force an empty
-- title.
function M.notify(msg, level, opts)
  local merged = vim.tbl_extend("force", { title = DEFAULT_TITLE }, opts or {})
  return vim.notify(msg, level, merged)
end

-- True for buffers that look like normal user-facing buffers
-- (listed, valid, and a regular file/empty buftype).
local function is_normal_listed_buffer(buf, exclude_buf)
  return buf ~= exclude_buf
    and vim.api.nvim_buf_is_valid(buf)
    and vim.fn.buflisted(buf) == 1
    and vim.bo[buf].buftype == ""
end

-- Find an existing listed file buffer (with a name) to display.
-- Returns nil if none exists.
-- Optional `should_skip(buf) -> bool` lets callers exclude certain buffers.
function M.find_file_buffer(exclude_buf, should_skip)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if is_normal_listed_buffer(buf, exclude_buf)
      and vim.api.nvim_buf_get_name(buf) ~= ""
      and (should_skip == nil or not should_skip(buf))
    then
      return buf
    end
  end
  return nil
end

-- Find an existing empty unnamed unmodified buffer suitable to display.
-- Returns nil if none exists.
function M.find_empty_unnamed_buffer(exclude_buf)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if is_normal_listed_buffer(buf, exclude_buf)
      and vim.api.nvim_buf_get_name(buf) == ""
      and not vim.bo[buf].modified then
      return buf
    end
  end
  return nil
end

-- Return the most recently used normal listed buffer, walking backwards
-- through the buffer MRU list.  Terminal buffers (buftype "terminal") are
-- always excluded by the `is_normal_listed_buffer` guard.
-- Optional `should_skip(buf) -> bool` lets callers exclude additional
-- buffers (e.g. prompt-file buffers).
function M.find_previous_buffer(exclude_buf, should_skip)
  local best = nil
  for _, info in ipairs(vim.fn.getbufinfo()) do
    local buf = info.bufnr
    if info.lastused > 0
      and is_normal_listed_buffer(buf, exclude_buf)
      and (should_skip == nil or not should_skip(buf))
      and (not best or info.lastused > best.lastused)
    then
      best = info
    end
  end
  return best and best.bufnr or nil
end

-- Find a buffer suitable for a window we're "giving back" to the user
-- (e.g. when leaving fullscreen or closing a transient prompt buffer).
--
-- Tries (in order):
--   1. the most recently used buffer (skipping terminals and, optionally,
--      anything `should_skip` rejects)
--   2. an existing real file buffer
--   3. an existing empty unnamed unmodified buffer
--   4. a freshly created listed buffer (last resort)
--
-- This avoids leaking new `[No Name]` buffers on every fullscreen exit
-- in workspaces where no other file is currently loaded.
function M.find_or_create_restore_buffer(exclude_buf, should_skip)
  local prev = M.find_previous_buffer(exclude_buf, should_skip)
  if prev then return prev end

  local found = M.find_file_buffer(exclude_buf, should_skip)
  if found then return found end

  local empty = M.find_empty_unnamed_buffer(exclude_buf)
  if empty then return empty end

  return vim.api.nvim_create_buf(true, false)
end

-- Soft-depend on markdown-table-wrap without force-loading lazy plugins.
-- Only consult modules that are already in package.loaded.
local function loaded_mtw()
  local mtw = package.loaded["markdown-table-wrap"]
  if type(mtw) == "table" then
    return mtw
  end
  return nil
end

local function loaded_mtw_reader()
  local reader = package.loaded["markdown-table-wrap.reader"]
  if type(reader) == "table" then
    return reader
  end
  return nil
end

-- Resolve the canonical file buffer behind virtual views (e.g. markdown-table-wrap
-- Reader / Float). Soft-depends on markdown-table-wrap: if the plugin is absent
-- or unloaded, falls back to buffer vars / the view buffer itself.
--
-- Prefer cheap gates (buffer var, float ownership, reader marker) so ordinary
-- Source buffers never pay for mtw.resolve_source_buffer → full context.resolve.
-- @param bufnr integer|nil View buffer (0 / nil = current)
-- @return { view_bufnr: integer, source_bufnr: integer, path: string }
function M.resolve_file_location(bufnr)
  if bufnr == nil or bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end

  local source_bufnr = bufnr

  -- Cheap: Reader buffer var (works even when mtw is unloaded).
  local from_var = vim.b[bufnr].markdown_table_wrap_source
  if from_var and vim.api.nvim_buf_is_valid(from_var) then
    source_bufnr = from_var
  end

  -- Cheap: Float ownership via public mtw.state fields.
  if source_bufnr == bufnr then
    local mtw = loaded_mtw()
    if mtw and type(mtw.state) == "table" then
      local st = mtw.state
      local float_src = st.float_source_bufnr
      if st.buf == bufnr and float_src and vim.api.nvim_buf_is_valid(float_src) then
        source_bufnr = float_src
      end
    end
  end

  -- Cheap: Reader module marker / source lookup (no context.resolve).
  if source_bufnr == bufnr then
    local reader = loaded_mtw_reader()
    if reader and type(reader.is_reader) == "function" and reader.is_reader(bufnr) then
      if type(reader.source_bufnr) == "function" then
        local src = reader.source_bufnr(bufnr)
        if src and vim.api.nvim_buf_is_valid(src) then
          source_bufnr = src
        end
      end
    end
  end

  -- Heavy fallback only when cheap gates hint at a virtual view but did not
  -- settle a remapped Source. Ordinary Source (no markers / not float) skips it.
  if source_bufnr == bufnr then
    local mtw = loaded_mtw()
    local looks_virtual = vim.b[bufnr].markdown_table_wrap_reader == true
      or vim.b[bufnr].markdown_table_wrap_source ~= nil
      or (mtw and type(mtw.state) == "table" and mtw.state.buf == bufnr)
    if looks_virtual and mtw and type(mtw.resolve_source_buffer) == "function" then
      local resolved = mtw.resolve_source_buffer(bufnr)
      if resolved and vim.api.nvim_buf_is_valid(resolved) then
        source_bufnr = resolved
      end
    end
  end

  return {
    view_bufnr = bufnr,
    source_bufnr = source_bufnr,
    path = vim.api.nvim_buf_get_name(source_bufnr),
  }
end

-- True when bufnr is the active markdown-table-wrap Float scratch, or is shown
-- in any window with a non-empty `relative` config (editor/win/cursor float).
-- Soft-dep only: never force-requires mtw.
-- @param bufnr integer
-- @return boolean
function M.is_float_view(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  local mtw = loaded_mtw()
  if mtw and type(mtw.state) == "table" and mtw.state.buf == bufnr then
    return true
  end

  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr then
      local cfg = vim.api.nvim_win_get_config(win)
      if cfg.relative and cfg.relative ~= "" then
        return true
      end
    end
  end

  return false
end

-- Tear down a float view. When the current window is the float, restore Source
-- focus; otherwise leave the current window alone (e.g. terminal after send).
-- mtw.close_preview is focus-scoped (can close Reader or pause/clear inline on
-- the terminal), so owned floats are torn down by known identity via mtw.state
-- win/buf/float_* fields only. Foreign floats: close windows showing bufnr.
-- mtw state is cleared only after the float win is actually gone.
-- Returns true only when the float is actually gone. Soft-dep via package.loaded.
-- @param bufnr integer view buffer
-- @return boolean
function M.close_float_view_if_needed(bufnr)
  if not M.is_float_view(bufnr) then
    return false
  end

  local mtw = loaded_mtw()
  local st = mtw and type(mtw.state) == "table" and mtw.state or nil
  local is_mtw_float = st and st.buf == bufnr
  local source_winid = is_mtw_float and st.float_source_winid or nil
  local cur_win = vim.api.nvim_get_current_win()
  local restore_source = false

  if is_mtw_float then
    -- Float-only teardown mirroring mtw's internal close_existing (not exported).
    local float_win = st.win
    if float_win and vim.api.nvim_win_is_valid(float_win) then
      restore_source = (cur_win == float_win)
      pcall(vim.api.nvim_win_close, float_win, true)
    end

    -- Only clear ownership after the float win is gone (or was already gone).
    local win_gone = not float_win or not vim.api.nvim_win_is_valid(float_win)
    if win_gone then
      if st.buf and vim.api.nvim_buf_is_valid(st.buf) then
        pcall(vim.api.nvim_buf_delete, st.buf, { force = true })
      end
      st.win = nil
      st.buf = nil
      st.float_source_bufnr = nil
      st.float_source_winid = nil
      st.float_source_alt_bufnr = nil
      st.float_rendered = nil
    end
  else
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr then
        local cfg = vim.api.nvim_win_get_config(win)
        if cfg.relative and cfg.relative ~= "" then
          pcall(vim.api.nvim_win_close, win, true)
        end
      end
    end
  end

  if restore_source and source_winid and vim.api.nvim_win_is_valid(source_winid) then
    pcall(vim.api.nvim_set_current_win, source_winid)
  end

  -- Success only when the float is actually gone (win closed / state cleared /
  -- no longer detected as a float view).
  return not M.is_float_view(bufnr)
end

-- Map a float view line to Source, clamping out-of-range indices to the
-- nearest mapped edge (avoids falling back to start_lnum and inverting ranges).
local function map_float_lnum(rendered, lnum)
  local source_lnums = rendered.source_lnums
  local mapped = source_lnums[lnum]
  if mapped then
    return mapped
  end

  local n = #source_lnums
  if n > 0 then
    if lnum < 1 then
      return source_lnums[1]
    end
    return source_lnums[n]
  end

  return rendered.end_lnum or rendered.start_lnum or lnum
end

-- Map a view line using an optional prefetched Reader state (avoids a second
-- get_state deepcopy when mapping a range). Float mapping stays cheap.
-- @param view_bufnr integer
-- @param lnum integer|nil
-- @param reader_state table|nil already-fetched reader.get_state result (or nil)
-- @return integer|nil
local function map_line_to_source_with_state(view_bufnr, lnum, reader_state)
  if lnum == nil then
    return lnum
  end

  if reader_state and reader_state.reader_to_source then
    return reader_state.reader_to_source[lnum] or lnum
  end

  local mtw = loaded_mtw()
  if mtw and type(mtw.state) == "table" then
    local st = mtw.state
    local rendered = st.float_rendered
    if st.buf == view_bufnr and rendered and rendered.source_lnums then
      return map_float_lnum(rendered, lnum)
    end
  end

  return lnum
end

-- Map a line number in a view buffer (Reader or Float) to the backing Source line.
-- Without a loaded markdown-table-wrap mapping, returns lnum unchanged.
-- @param view_bufnr integer|nil (0 / nil = current)
-- @param lnum integer|nil
-- @return integer|nil
function M.map_line_to_source(view_bufnr, lnum)
  if lnum == nil then
    return lnum
  end
  if view_bufnr == nil or view_bufnr == 0 then
    view_bufnr = vim.api.nvim_get_current_buf()
  end

  local reader_state = nil
  local reader = loaded_mtw_reader()
  if reader and type(reader.get_state) == "function" then
    reader_state = reader.get_state(view_bufnr)
  end

  return map_line_to_source_with_state(view_bufnr, lnum, reader_state)
end

-- Map the live view cursor to Source via public mtw APIs already used elsewhere.
-- `reader.source_position` maps Reader line+column; Float has no column map.
-- Returns nil when unmapped so callers apply a defined fallback — do not apply
-- a view byte column to a differently laid-out source line.
-- @param view_bufnr integer
-- @param winid integer|nil window that still shows the view
-- @return { lnum: integer, col: integer }|nil
function M.map_view_cursor_to_source(view_bufnr, winid)
  if not view_bufnr or not vim.api.nvim_buf_is_valid(view_bufnr) then
    return nil
  end
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return nil
  end
  if vim.api.nvim_win_get_buf(winid) ~= view_bufnr then
    return nil
  end

  local reader = loaded_mtw_reader()
  if reader
    and type(reader.source_position) == "function"
    and type(reader.is_reader) == "function"
    and reader.is_reader(view_bufnr)
  then
    local pos = reader.source_position(view_bufnr, winid)
    -- { source_bufnr, lnum, col }
    if type(pos) == "table" and type(pos[2]) == "number" and type(pos[3]) == "number" then
      return { lnum = pos[2], col = pos[3] }
    end
  end

  return nil
end

-- Resolve path + Source-mapped line range for clipboard / visual / :PTCopyLink.
-- Prefetches Reader state once so both endpoints share a single get_state deepcopy.
-- @param line1 integer View start line
-- @param line2 integer|nil View end line (defaults to line1)
-- @param bufnr integer|nil View buffer (0 / nil = current)
-- @return { path: string, line1: integer, line2: integer, view_bufnr: integer, source_bufnr: integer }
function M.resolve_range_location(line1, line2, bufnr)
  local loc = M.resolve_file_location(bufnr)
  local view_bufnr = loc.view_bufnr

  local reader_state = nil
  local reader = loaded_mtw_reader()
  if reader and type(reader.get_state) == "function" then
    reader_state = reader.get_state(view_bufnr)
  end

  local mapped1 = map_line_to_source_with_state(view_bufnr, line1, reader_state)
  local mapped2 = map_line_to_source_with_state(view_bufnr, line2 or line1, reader_state)
  -- Normalize so inverted float/reader edge maps never yield line1 > line2.
  if mapped1 and mapped2 and mapped1 > mapped2 then
    mapped1, mapped2 = mapped2, mapped1
  end
  return {
    view_bufnr = loc.view_bufnr,
    source_bufnr = loc.source_bufnr,
    path = loc.path,
    line1 = mapped1,
    line2 = mapped2,
  }
end

-- True when the window is floating (`relative` is non-empty).
-- @param win integer
-- @return boolean
function M.is_float_window(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return false
  end
  local cfg = vim.api.nvim_win_get_config(win)
  return cfg.relative and cfg.relative ~= ""
end

-- True when `win` is in the current tabpage (win_id2win is 0 otherwise).
-- @param win integer
-- @return boolean
function M.win_in_current_tab(win)
  return win ~= nil
    and vim.api.nvim_win_is_valid(win)
    and vim.fn.win_id2win(win) ~= 0
end

-- True when a prompt must not replace this window as origin: float, any
-- terminal job, command-line window (E11), prompt/quickfix buftype,
-- previewwindow, or any window with winfixwidth/height/buf (pinned file,
-- sidebar, winfixbuf). Plugin identity (Reader, fugitive, oil, …) is
-- not consulted; help/oil without those flags remain replaceable.
-- @param win integer
-- @return boolean
function M.is_protected_window(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return true
  end
  if M.is_float_window(win) then
    return true
  end
  -- getcmdwintype is session-global; only the current window is the cmdwin.
  if vim.fn.getcmdwintype() ~= "" and win == vim.api.nvim_get_current_win() then
    return true
  end
  local buf = vim.api.nvim_win_get_buf(win)
  if not vim.api.nvim_buf_is_valid(buf) then
    return true
  end
  local bt = vim.bo[buf].buftype
  if bt == "terminal" or bt == "prompt" or bt == "quickfix" then
    return true
  end
  return vim.wo[win].winfixwidth
    or vim.wo[win].winfixheight
    or vim.wo[win].winfixbuf
    or vim.wo[win].previewwindow
end

-- True when `win` is in the current tab and a prompt may replace it
-- (normal file, Reader, fugitive status, oil, help, …). Protected
-- windows (float, terminal, cmdwin, prompt/quickfix, winfix/preview)
-- are excluded.
-- @param win integer
-- @return boolean
function M.is_non_terminal_window(win)
  return M.win_in_current_tab(win) and not M.is_protected_window(win)
end

-- True when `win` is a non-float in the current tab showing a normal file
-- buffer (empty buftype). Independent of the prompt mount denylist: a
-- pinned or preview file window still counts so window_showing_buffer /
-- preset insert can find Source. Skips terminals, help, quickfix, and
-- other non-file windows.
-- @param win integer
-- @return boolean
function M.is_editable_window(win)
  if not M.win_in_current_tab(win) or M.is_float_window(win) then
    return false
  end
  local buf = vim.api.nvim_win_get_buf(win)
  return vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == ""
end

-- Snap a 0-based byte column onto a UTF-8 character boundary of `line`.
-- nvim_buf_set_text rejects mid-sequence columns; view-byte columns from
-- Reader/Float (or wrapped lines) can land in the middle of a character.
-- @param line string
-- @param col integer|nil
-- @return integer
function M.clamp_col_to_char_boundary(line, col)
  line = line or ""
  local len = #line
  col = math.max(0, math.min(tonumber(col) or 0, len))
  if col == 0 or col == len then
    return col
  end
  -- charidx maps a trailing byte to that character; byteidx is its start.
  local cidx = vim.fn.charidx(line, col)
  if type(cidx) == "number" and cidx >= 0 then
    local bidx = vim.fn.byteidx(line, cidx)
    if type(bidx) == "number" and bidx >= 0 then
      return bidx
    end
  end
  -- vim.str_utf_start is 1-based; 0 at a character start, negative if mid-sequence.
  local start = vim.str_utf_start(line, col + 1)
  if type(start) == "number" then
    return col + start
  end
  return col
end

-- Non-floating file window in the current tab displaying `bufnr`, or nil.
-- Prefers the current window when it already shows the buffer.
-- @param bufnr integer
-- @return integer|nil
function M.window_showing_buffer(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local cur = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(cur) == bufnr and M.is_editable_window(cur) then
    return cur
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_is_valid(win)
      and vim.api.nvim_win_get_buf(win) == bufnr
      and M.is_editable_window(win)
    then
      return win
    end
  end
  return nil
end

-- Window to split relative to when the prompt must not replace the origin.
-- Winfix/preview mean "do not replace", not "do not split from". Rank:
-- ordinary file (editable, not protected) > pinned/preview file > help/
-- oil/scratch (other non-protected mounts). Sidebars/terminals/floats/
-- cmdwin/quickfix are skipped so the caller can fall back to splitting `cur`.
-- @return integer|nil
function M.first_non_terminal_window()
  local cur = vim.api.nvim_get_current_win()
  local wins = vim.api.nvim_tabpage_list_wins(0)
  local function first(pred)
    if pred(cur) then
      return cur
    end
    for _, win in ipairs(wins) do
      if pred(win) then
        return win
      end
    end
    return nil
  end
  return first(function(win)
    return M.is_editable_window(win) and not M.is_protected_window(win)
  end) or first(function(win)
    return M.is_editable_window(win)
  end) or first(function(win)
    return M.is_non_terminal_window(win)
  end)
end

-- Timestamp prefix YYYY-MM-DD_HH-MM-SS. The seconds field ends at the end
-- of the name or at a character that is neither a digit nor a letter, so
-- "0399_..." and "03weekly" are not 11:15:03. "_" and "." still separate it.
-- Impossible dates that os.time would normalize (month 99, 31 Feb, …) are
-- rejected so the caller can use mtime.
-- @return number|nil unix time
function M.parse_timestamp_from_filename(filename)
  local y, mo, d, h, mi, s =
    filename:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)_(%d%d)%-(%d%d)%-(%d%d)$")
  if not y then
    y, mo, d, h, mi, s =
      filename:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)_(%d%d)%-(%d%d)%-(%d%d)([^%d%a])")
  end
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

-- Telescope sorter that keeps finder order while the prompt is empty.
-- Built on top of conf.file_sorter({}), which may be telescope-fzf-native.
-- The picker runs the sorter lifecycle (init/start/finish/destroy) on this
-- wrapper, never on the base. fzf-native stores its slab and prompt cache in
-- init and frees them in destroy, so the lifecycle must be forwarded to the
-- base or the first typed query indexes an uninitialized state.
-- fzf-native's start also clears its own discard set because "|" and "!" are
-- not prefix-monotonic. Telescope records discards on this wrapper, so copying
-- discard would keep a miss hidden when the prompt only grows. A sorter with
-- no start function keeps its own discard flag.
-- `and false or` cannot be used for that: false is discarded by `or`.
-- Telescope is required lazily so this module does not hard-depend on it.
-- @param base_sorter table telescope sorters.Sorter
-- @return table telescope sorters.Sorter
function M.chronological_sorter(base_sorter)
  local sorters = require("telescope.sorters")

  local function forward_to_base(method)
    if type(base_sorter[method]) ~= "function" then
      return nil
    end
    return function(_, ...)
      return base_sorter[method](base_sorter, ...)
    end
  end

  local discard_flag = base_sorter.discard
  if type(base_sorter.start) == "function" then
    discard_flag = false
  end

  return sorters.Sorter:new({
    discard = discard_flag,
    init = forward_to_base("init"),
    start = forward_to_base("start"),
    finish = forward_to_base("finish"),
    destroy = forward_to_base("destroy"),
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
end

-- Enable wrap/linebreak/breakindent on a window (Telescope preview).
-- Plugin requires Neovim 0.11, so nvim_set_option_value is always present.
function M.apply_wrap(winid)
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return
  end
  pcall(vim.api.nvim_set_option_value, "wrap", true, { win = winid })
  pcall(vim.api.nvim_set_option_value, "linebreak", true, { win = winid })
  pcall(vim.api.nvim_set_option_value, "breakindent", true, { win = winid })
end

return M
