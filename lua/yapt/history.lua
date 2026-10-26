-- Prompt history workflow for yapt.nvim plugin
--
-- Provides:
-- - Creating a new markdown file in ${CWD}/.nvim-yapt/history/ with timestamp in filename
-- - Sending the current file contents to the active terminal
--
local terminal = require("yapt.terminal")
local tabs = require("yapt.tabs")
local picker = require("yapt.picker")
local util = require("yapt.util")

local M = {}

-- Create history directory path (relative to CWD)
local function history_dir_path(cfg)
  local cwd = vim.fn.getcwd()
  local dir = (cfg and cfg.history and cfg.history.dir) or ".nvim-yapt/history"
  if dir:match("^/") then
    return dir
  end
  return cwd .. "/" .. dir:gsub("/$", "")
end

-- Return sorted history entries (new -> old).
-- Sorting strategy:
-- 1) Prefer timestamp parsed from filename (YYYY-MM-DD_HH-MM-SS.md)
-- 2) Fallback to filesystem mtime (seconds)
-- 3) Tie-break by filename (descending)
local function list_history_files_sorted(config)
  config = config or {}
  local dir = history_dir_path(config)

  if vim.fn.isdirectory(dir) ~= 1 then
    return {}, dir
  end

  local files = vim.fn.readdir(dir)
  local entries = {}

  for _, f in ipairs(files) do
    if f:match("%.md$") then
      local fullpath = dir .. "/" .. f
      local ts = util.parse_timestamp_from_filename(f)

      if not ts then
        local ft = vim.fn.getftime(fullpath)
        if type(ft) == "number" and ft >= 0 then
          ts = ft
        else
          ts = 0
        end
      end

      table.insert(entries, {
        name = f,
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

local function is_plugin_prompt_file_buffer(buf, config)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return false
  end

  if vim.bo[buf].buftype ~= "" then
    return false
  end

  local path = vim.api.nvim_buf_get_name(buf)
  if not path or path == "" then
    return false
  end

  local abs_path = vim.fn.fnamemodify(path, ":p")
  local history_dir = vim.fn.fnamemodify(history_dir_path(config), ":p"):gsub("/$", "")
  local history_prefix = history_dir .. "/"

  if abs_path:sub(1, #history_prefix) ~= history_prefix then
    return false
  end

  local filename = vim.fn.fnamemodify(abs_path, ":t")
  -- Only .md files are listed as prompts, so only they are plugin prompt
  -- buffers. The shared parser accepts any extension, hence the extra test.
  return filename:match("%.md$") ~= nil
    and util.parse_timestamp_from_filename(filename) ~= nil
end

-- Persist a prompt-file buffer to disk when the user leaves it, so it shows
-- up in the history Telescope picker (:PTHistory) and :PTLast without a
-- manual :write. No-op unless the buffer is a plugin prompt file and has
-- unsaved changes; an empty just-created prompt you abandon is left alone.
local function autosave_prompt_buffer(buf, config)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  if not is_plugin_prompt_file_buffer(buf, config) then
    return
  end
  if not vim.bo[buf].modified then
    return
  end

  local path = vim.api.nvim_buf_get_name(buf)
  if not path or path == "" then
    return
  end

  local dir = history_dir_path(config)
  if vim.fn.isdirectory(dir) ~= 1 then
    vim.fn.mkdir(dir, "p")
  end

  -- Use :write (not writefile) so Neovim updates the buffer's file timestamp
  -- and does not prompt to reload when returning to the buffer.
  local ok = pcall(function()
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("silent! noautocmd write")
    end)
  end)
  if not ok then
    util.notify("Failed to autosave prompt file: " .. path, vim.log.levels.WARN)
  end
end

-- Register autocmds that persist prompt-file buffers to disk when the user
-- leaves them (or quits Neovim), so they appear in the history Telescope
-- picker without a manual :write. Idempotent: recreates the augroup on each
-- call.
function M.setup_autosave_autocmds(config)
  local group = vim.api.nvim_create_augroup("yapt_history_autosave", { clear = true })
  vim.api.nvim_create_autocmd({ "BufLeave", "BufHidden" }, {
    group = group,
    callback = function(args)
      autosave_prompt_buffer(args.buf, config)
    end,
  })
  -- Quitting Neovim fires no per-buffer leave event for the current buffer,
  -- so sweep every loaded prompt buffer on exit to avoid losing changes.
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) then
          autosave_prompt_buffer(buf, config)
        end
      end
    end,
  })
end

local function replace_prompt_in_open_windows(buf, replacement)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
      local cfg = vim.api.nvim_win_get_config(win)
      -- Never mount a normal buffer into a floating window (e.g. mtw Float).
      if not (cfg.relative and cfg.relative ~= "") then
        vim.api.nvim_win_set_buf(win, replacement)
      end
    end
  end
end

-- Treat view_buf as live only while it still resolves to source_buf.
-- Protects deferred close (~100–200ms after fullscreen prepare) from a
-- recycled bufnr after float wipe / Reader abandon.
-- @param source_buf integer
-- @param view_buf integer|nil
-- @return integer live view (or source_buf when stale / missing)
local function live_view_for_source(source_buf, view_buf)
  view_buf = view_buf or source_buf
  if view_buf == source_buf then
    return source_buf
  end
  if not vim.api.nvim_buf_is_valid(view_buf) then
    return source_buf
  end
  if util.resolve_file_location(view_buf).source_bufnr == source_buf then
    return view_buf
  end
  return source_buf
end

-- Swap view/source windows to `replacement`. Float views are torn down first
-- (focus returns to Source); Reader/normal keep the view+source swap path.
-- @param source_buf integer
-- @param view_buf integer
-- @param replacement integer
local function swap_prompt_windows_for_view(source_buf, view_buf, replacement)
  view_buf = live_view_for_source(source_buf, view_buf)
  if util.close_float_view_if_needed(view_buf) then
    replace_prompt_in_open_windows(source_buf, replacement)
    return
  end

  replace_prompt_in_open_windows(view_buf, replacement)
  if view_buf ~= source_buf then
    replace_prompt_in_open_windows(source_buf, replacement)
  end
end

-- Close/fullscreen window ops must target the visible buffer (view), while
-- prompt identity and wipe use Source (real file behind Reader/Float).
-- @param source_buf integer real file buffer
-- @param config Plugin config
-- @param view_buf integer|nil visible buffer (defaults to source_buf)
local function close_sent_prompt_buffer_if_needed(source_buf, config, view_buf)
  if not is_plugin_prompt_file_buffer(source_buf, config) then
    return
  end

  view_buf = live_view_for_source(source_buf, view_buf)

  local skip_prompt = function(b)
    return is_plugin_prompt_file_buffer(b, config)
  end

  local replacement = util.find_previous_buffer(source_buf, skip_prompt)
    or util.find_file_buffer(source_buf, skip_prompt)
    or util.find_empty_unnamed_buffer(source_buf)

  if not replacement then
    return
  end

  swap_prompt_windows_for_view(source_buf, view_buf, replacement)

  local ok, err = pcall(vim.api.nvim_buf_delete, source_buf, {})
  if not ok then
    util.notify("Failed to close sent prompt buffer: " .. tostring(err), vim.log.levels.WARN)
    return
  end
end

-- @param source_buf integer real file buffer
-- @param config Plugin config
-- @param view_buf integer|nil visible buffer (defaults to source_buf)
local function prepare_prompt_buffer_for_fullscreen(source_buf, config, view_buf)
  if not is_plugin_prompt_file_buffer(source_buf, config) then
    return
  end

  view_buf = live_view_for_source(source_buf, view_buf)

  local skip_prompt = function(b)
    return is_plugin_prompt_file_buffer(b, config)
  end

  local replacement = util.find_or_create_restore_buffer(source_buf, skip_prompt)
  swap_prompt_windows_for_view(source_buf, view_buf, replacement)
end

-- Expose history dir path for other modules
function M.history_dir_path(config)
  return history_dir_path(config)
end

-- Exact buffer whose name is `path` (`nvim_buf_get_name` vs `:p`).
-- Unanchored bufnr(path) is a file-name pattern and can hit the wrong buffer.
-- @param path string
-- @return integer|nil
local function buffer_with_path(path)
  if not path or path == "" then
    return nil
  end
  local abs = vim.fn.fnamemodify(path, ":p")
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" and vim.fn.fnamemodify(name, ":p") == abs then
        return buf
      end
    end
  end
  return nil
end

local function loaded_buffer_with_path(path)
  local buf = buffer_with_path(path)
  if buf and vim.api.nvim_buf_is_loaded(buf) then
    return buf
  end
  return nil
end

-- True when `fullpath` is already used on disk or as a buffer name.
-- Unsaved :PTPrompt buffers are named YYYY-MM-DD_HH-MM-SS.md but are not
-- filereadable; treating only disk files as taken would collide with them.
-- uv.fs_stat is Neovim's fileexists equivalent (any inode, including
-- unreadable files that filereadable misses). Buffer identity is exact
-- (nvim_buf_get_name / bufexists), never unanchored bufnr().
local function history_path_taken(fullpath)
  local abs = vim.fn.fnamemodify(fullpath, ":p")
  if vim.uv.fs_stat(fullpath) ~= nil or vim.uv.fs_stat(abs) ~= nil then
    return true
  end
  if buffer_with_path(fullpath) then
    return true
  end
  return vim.fn.bufexists(fullpath) == 1 or vim.fn.bufexists(abs) == 1
end

-- Build a unique timestamped history file path (.md), guarding against
-- same-second collisions by appending _1, _2, ... before the extension.
-- Collision-suffixed names still parse via util.parse_timestamp_from_filename.
-- `extra_taken` is always treated as occupied (e.g. a colliding path
-- unique_history_path would otherwise re-pick).
local function unique_history_path(dir, extra_taken)
  local base = os.date("%Y-%m-%d_%H-%M-%S")
  local fullpath = dir .. "/" .. base .. ".md"
  local counter = 1
  while history_path_taken(fullpath) or fullpath == extra_taken do
    fullpath = dir .. "/" .. base .. "_" .. counter .. ".md"
    counter = counter + 1
  end
  return fullpath
end

-- If a loaded buffer already uses `path`, bufadd/bufload would reuse it
-- (bufload is a no-op) and show that buffer's text instead of the file.
-- Relocate a just-written file (or pick a free name) until the name is free.
-- Never returns a path a loaded buffer still owns (fail rather than collide).
-- @return string|nil path that no loaded buffer owns, or nil on failure
local function avoid_loaded_history_buffer(path)
  if not loaded_buffer_with_path(path) then
    return path
  end

  local dir = vim.fn.fnamemodify(path, ":h")
  local dest = unique_history_path(dir, path)
  if dest == path or loaded_buffer_with_path(dest) then
    return nil
  end

  if vim.fn.filereadable(path) ~= 1 then
    -- Named but not on disk (empty :PTPrompt): open under the free name.
    return dest
  end

  if vim.fn.rename(path, dest) == 0 and vim.fn.filereadable(dest) == 1 then
    return dest
  end
  local copied = pcall(function()
    vim.fn.writefile(vim.fn.readfile(path), dest)
  end)
  if copied and vim.fn.filereadable(dest) == 1 then
    -- Leave the colliding path empty on disk so the unsaved buffer's
    -- autosave cannot overwrite the relocated clone.
    pcall(vim.fn.delete, path)
    return dest
  end
  return nil
end

-- Create the history directory if needed. Returns the path, or nil on failure.
-- Shared by write_prompt_file (clone/send) and empty :PTPrompt (named buffer,
-- unwritten until save — do not write an empty file here).
-- @return string|nil
local function ensure_history_dir(config)
  local dir = history_dir_path(config)
  pcall(vim.fn.mkdir, dir, "p")
  if vim.fn.isdirectory(dir) ~= 1 then
    util.notify("Failed to create history directory: " .. dir, vim.log.levels.ERROR)
    return nil
  end
  return dir
end

-- Write a new timestamped prompt-history file without opening it.
-- @param lines string[] file lines (may be empty)
-- @return string|nil full path of the created file, or nil on failure
function M.write_prompt_file(config, lines)
  config = config or {}
  lines = lines or {}
  local dir = ensure_history_dir(config)
  if not dir then
    return nil
  end

  -- Choose a name no loaded buffer owns, then write. Writing first and
  -- relocating later can leave clone bytes at `fullpath` while an unsaved
  -- :PTPrompt still owns that name (autosave would overwrite the clone).
  local fullpath = unique_history_path(dir)
  if loaded_buffer_with_path(fullpath) then
    local dest = unique_history_path(dir, fullpath)
    if dest == fullpath or loaded_buffer_with_path(dest) then
      util.notify("Failed to write history file: " .. fullpath, vim.log.levels.ERROR)
      return nil
    end
    fullpath = dest
  end

  local wrote = pcall(vim.fn.writefile, lines, fullpath)
  if not wrote or vim.fn.filereadable(fullpath) ~= 1 then
    util.notify("Failed to write history file: " .. fullpath, vim.log.levels.ERROR)
    return nil
  end
  -- unique_history_path already skipped buffers; relocate if a loaded
  -- buffer still owns this name so later bufload cannot reuse it.
  local dest = avoid_loaded_history_buffer(fullpath)
  if not dest then
    -- Relocate failed; do not leave clone bytes on a path a loaded
    -- buffer still owns.
    if loaded_buffer_with_path(fullpath) then
      pcall(vim.fn.delete, fullpath)
    end
    util.notify("Failed to write history file: " .. fullpath, vim.log.levels.ERROR)
    return nil
  end
  return dest
end

-- Persist an unnamed/new buffer to a fresh prompt-history file, converting
-- the buffer in place so it becomes a recognized plugin prompt-file buffer.
-- Reuses the same naming scheme (timestamped .md) as create_prompt_file.
-- @param lines string[] buffer lines to write (computed once by the caller)
-- @return string|nil full path of the created file, or nil on failure
local function persist_unnamed_buffer_to_history(buf, lines, config)
  local fullpath = M.write_prompt_file(config, lines)
  if not fullpath then
    return nil
  end

  -- Convert the buffer in place: it now IS the history prompt file, so it
  -- satisfies is_plugin_prompt_file_buffer and inherits close-after-send.
  local renamed, err = pcall(vim.api.nvim_buf_set_name, buf, fullpath)
  if not renamed then
    util.notify("Failed to associate buffer with history file: " .. tostring(err), vim.log.levels.ERROR)
    return nil
  end
  vim.bo[buf].modified = false

  return fullpath
end

-- Hide a fullscreen YAPT terminal in the current tab so the restored
-- file window can be used as a mount. Looks at every window in the tab,
-- not only the current one (sidebar + fullscreen would otherwise skip
-- hide and split the sidebar). When the origin was that fullscreen
-- terminal, the restored window is the in-place mount (same as F12).
-- When the origin was a split terminal, explorer, or float, the
-- restored file is not an in-place mount: the caller still splits.
-- Split terminals are not hidden:
-- nvim_win_hide does not create a file window, and can succeed while
-- leaving no mount (help/qf/explorer still there) with the terminal gone.
-- @return string|nil hidden terminal id (restore if open still cannot proceed)
-- @return integer|nil window that held the fullscreen terminal
local function hide_fullscreen_mount()
  if not terminal.is_fullscreen_in_current_tab() then
    return nil, nil
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_is_valid(win) then
      local id = terminal.id_for_buf(vim.api.nvim_win_get_buf(win))
      if id and terminal.is_fullscreen_in_current_tab(id) then
        terminal.hide(id)
        return id, win
      end
    end
  end
  return nil, nil
end

-- Re-show a fullscreen terminal hidden for an in-tab open. Must take
-- over `win` (the window that was hidden), not nvim_get_current_win():
-- after :new / :vnew / :tabnew the current window is the leftover split.
local function restore_fullscreen_mount(id, win)
  if not id then
    return
  end
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_set_current_win, win)
  end
  pcall(terminal.show_fullscreen, id)
end

-- Drop an empty unnamed file buffer that no window shows (placeholder
-- from open_edit_split / :tabnew after the prompt is mounted).
local function wipe_orphaned_placeholder(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  if vim.api.nvim_buf_get_name(buf) ~= ""
    or vim.bo[buf].modified
    or vim.bo[buf].buftype ~= ""
  then
    return
  end
  if #vim.fn.win_findbuf(buf) > 0 then
    return
  end
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end

-- New split showing an unlisted empty file buffer, so the prompt can mount
-- without stealing a protected window. Never opens into a float.
-- From a sidebar/terminal/leftover float, split relative to a sibling
-- file (ordinary file first, then pinned/preview) or other mount; do not
-- replace that buffer, and do not split the sidebar when a file exists.
-- A float is never a mount: only fail when this tab has no split ancestor
-- and `cur` itself is a float.
-- @param vertical boolean|nil true = vertical split (Telescope <C-v> / :vnew)
-- @return integer|nil new window id
local function open_edit_split(vertical)
  local cur = vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(cur) then
    return nil
  end

  -- Prefer a sibling ordinary file, then pinned/preview, then help/oil,
  -- when `cur` is a sidebar/terminal; fall back to `cur` when this tab
  -- has no such window and `cur` itself can be split.
  local split_from = util.first_non_terminal_window()
  if not split_from then
    if util.is_float_window(cur) then
      return nil
    end
    split_from = cur
  end

  -- Unlisted empty file buffer (not scratch): scratch sets buftype=nofile,
  -- and wipe_orphaned_placeholder only drops unnamed file buffers.
  local buf = vim.api.nvim_create_buf(false, false)
  if not buf or buf == 0 then
    return nil
  end

  -- :split fallback may :wincmd to split_from. Restore `cur` on every
  -- failure so the caller never mounts into that sibling file window.
  local function abort_split()
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
    if vim.api.nvim_win_is_valid(cur) then
      pcall(vim.api.nvim_set_current_win, cur)
    end
    return nil
  end

  -- Match :new / :vnew (Telescope <C-x> / <C-v>): honor 'splitbelow' /
  -- 'splitright'.
  local split_dir, split_fallback
  if vertical then
    split_dir = vim.o.splitright and "right" or "left"
    split_fallback = "vsplit"
  else
    split_dir = vim.o.splitbelow and "below" or "above"
    split_fallback = "split"
  end
  local ok, new_win = pcall(vim.api.nvim_open_win, buf, true, {
    split = split_dir,
    win = split_from,
  })
  if ok and type(new_win) == "number" and vim.api.nvim_win_is_valid(new_win) then
    return new_win
  end

  if split_from ~= vim.api.nvim_get_current_win()
    and vim.api.nvim_win_is_valid(split_from)
  then
    pcall(vim.api.nvim_set_current_win, split_from)
  end
  ok = pcall(vim.cmd, split_fallback)
  if ok then
    local win = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_is_valid(win) and win ~= split_from then
      pcall(vim.api.nvim_win_set_buf, win, buf)
      return win
    end
  end

  return abort_split()
end

-- True when the current window may be replaced by a prompt.
local function current_win_is_mount()
  return util.is_non_terminal_window(vim.api.nvim_get_current_win())
end

-- Split unless `win` may be replaced in-place. False for a YAPT
-- fullscreen terminal (hide, then mount in the restored file window,
-- including when that file has winfix/preview). True for any other
-- protected window (float, split terminal, winfix sidebar, pinned file).
-- False for ordinary editor views (file, Reader, fugitive, …).
-- After hide, ensure_normal_edit_window may still split: a restored
-- winfix sidebar or winfixbuf window cannot take the prompt.
-- @param win integer|nil nil = current window
-- @return boolean
function M.must_split_from_window(win)
  win = win or vim.api.nvim_get_current_win()
  if not win or not vim.api.nvim_win_is_valid(win) then
    return true
  end
  local id = terminal.id_for_buf(vim.api.nvim_win_get_buf(win))
  if id and terminal.is_fullscreen_in_current_tab(id) then
    return false
  end
  return util.is_protected_window(win)
end

-- True when `win` may receive the prompt buffer. Floats, terminals, and
-- winfixbuf are always refused (E1513). A file with winfixwidth/height/
-- preview is allowed (fullscreen hide into the restored file, same as F12;
-- also a split/tab the plugin just created, even if WinNew pinned it). A
-- winfix sidebar (nvim-tree, aerial, …) is not a file and is refused; the
-- caller splits instead of aborting.
-- @param win integer
-- @return boolean
local function window_accepts_prompt(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return false
  end
  if util.is_float_window(win) or not util.win_in_current_tab(win) then
    return false
  end
  local buf = vim.api.nvim_win_get_buf(win)
  if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype == "terminal" then
    return false
  end
  if vim.wo[win].winfixbuf then
    return false
  end
  return util.is_non_terminal_window(win) or util.is_editable_window(win)
end

-- Drop 'previewwindow' on a prompt destination so :pclose / CTRL-W z
-- does not close it. Vim sets 'winfixheight' with the preview UI; clear
-- that too so the prompt is not stuck at 'previewheight'. Leave
-- winfixwidth/height on a pinned file that is not a preview window.
-- @param win integer
local function clear_preview_destination(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  if not vim.wo[win].previewwindow then
    return
  end
  pcall(vim.api.nvim_set_option_value, "previewwindow", false, { win = win })
  pcall(vim.api.nvim_set_option_value, "winfixheight", false, { win = win })
end

-- Leave mtw Float views and hide a fullscreen YAPT terminal before mounting
-- a normal file buffer. Reuse the current window when it is already a
-- mount. Never jump to a sibling file window (that replaces the user's
-- code buffer from a terminal or explorer). Never put a normal buffer in
-- a float, and never replace a terminal in-place.
-- After hiding fullscreen from a protected origin (split terminal /
-- sidebar / float), the restored file window is not "already editing":
-- the caller must still split rather than mount in that restored window.
-- Exception: when the origin *is* the fullscreen terminal (:PTPrompt /
-- <leader>ah), hide then mount in the restored window (same as F12),
-- even if that file window has winfix/preview. Winfix/preview still
-- mean must_split when they are the *origin* (pinned file → split).
-- A restored winfix sidebar or winfixbuf window is not that exception:
-- upgrade must_split so the caller splits rather than stealing the tree
-- or hitting E1513.
-- Closing an mtw Float likewise restores Source; capture origin *before*
-- that teardown or the restored file looks like an in-place mount.
-- Picker teardown (Telescope / vim.ui.select) happens *before* this
-- function: focus loss can dismiss an mtw Float, after which Source looks
-- like an in-place mount. Callers that snapshot at picker-open pass
-- `must_split` from the captured origin window; do not recompute it from
-- the current window after the picker. An explicit true keeps splitting
-- even when origin was a fullscreen terminal.
-- open_cmd "tabedit" skips origin-tab teardown (float close and fullscreen
-- hide): a new tab must not close an mtw Float or hide fullscreen in the
-- origin tab (on abort, show_fullscreen would also take over the leftover
-- :tabnew window).
-- @param loc table|nil resolve_file_location() captured by the caller
-- @param open_cmd string|nil nil | "new" | "vnew" | "tabedit"
-- @param must_split boolean|nil whether the caller should split after teardown.
--   nil = compute from the current window before this function's teardown
--   (false when that window is a fullscreen YAPT terminal; otherwise true
--   when the window is protected). An explicit value is kept as-is.
-- @return string|nil hidden fullscreen terminal id
-- @return integer|nil window that held the fullscreen terminal
-- @return boolean must_split whether the caller should split (false to mount
--   in the current/restored window, including fullscreen-terminal origin)
local function ensure_normal_edit_window(loc, open_cmd, must_split)
  if open_cmd == "tabedit" then
    return nil, nil, false
  end

  loc = loc or util.resolve_file_location()
  local view_buf = loc.view_bufnr

  -- Before float close / fullscreen hide: origin float / split terminal /
  -- sidebar must still split after the restored Source looks like a file
  -- mount. Fullscreen YAPT terminal origin is the other way: hide then
  -- mount in that window unless the caller already snapshotted must_split.
  if must_split == nil then
    must_split = M.must_split_from_window()
  end

  if view_buf then
    util.close_float_view_if_needed(view_buf)
  end

  if not must_split and current_win_is_mount() then
    return nil, nil, false
  end

  local hidden_id, restored_win = hide_fullscreen_mount()
  if restored_win
    and vim.api.nvim_win_is_valid(restored_win)
    and not util.is_float_window(restored_win)
  then
    -- must_split false: hide-then-mount in this window (same as F12) when
    -- it is a file, even with winfix/preview. must_split true: jump if the
    -- restored window is a file or other mount, so the following split is
    -- relative to it rather than a leftover sidebar.
    if not must_split
      or util.is_non_terminal_window(restored_win)
      or util.is_editable_window(restored_win)
    then
      pcall(vim.api.nvim_set_current_win, restored_win)
    end
  end
  -- Fullscreen origin keeps must_split false only when the restored window
  -- can take the prompt. A restored winfix sidebar or winfixbuf window
  -- must still split (do not abort-and-restore-fullscreen).
  if not must_split
    and not window_accepts_prompt(vim.api.nvim_get_current_win())
  then
    must_split = true
  end
  return hidden_id, restored_win, must_split
end

-- Open `path` without :edit (E37 / 'confirm' abort) and without deleting it.
-- bufadd + bufload, then nvim_win_set_buf on the captured mount window
-- (FileType hooks can steal the current window). `:hide buffer` in that
-- window keeps a modified buffer when 'hidden' is off.
-- May relocate via avoid_loaded_history_buffer; callers must use the
-- returned path (not the argument) for notify/return.
-- @param path string
-- @param loc table|nil
-- @param open_cmd string|nil nil = mount in current/new split;
--   "new" | "vnew" | "tabedit" = that split/tab after hide/mount prep
--   ("tabedit" skips origin-tab teardown so the origin tab is unchanged)
-- @param origin_must_split boolean|nil snapshot from picker-open;
--   nil = compute from the current window inside ensure_normal_edit_window
-- @return string|nil path that was actually opened, or nil on failure
local function open_prompt_path(path, loc, open_cmd, origin_must_split)
  local hidden_id, hidden_win, must_split =
    ensure_normal_edit_window(loc, open_cmd, origin_must_split)
  local leftover_win = nil

  local function abort_open(reason, created_buf)
    if leftover_win
      and vim.api.nvim_win_is_valid(leftover_win)
      and leftover_win ~= hidden_win
    then
      local leftover_buf = vim.api.nvim_win_get_buf(leftover_win)
      pcall(vim.api.nvim_win_close, leftover_win, true)
      wipe_orphaned_placeholder(leftover_buf)
    end
    restore_fullscreen_mount(hidden_id, hidden_win)
    if created_buf
      and vim.api.nvim_buf_is_valid(created_buf)
      and #vim.fn.win_findbuf(created_buf) == 0
    then
      pcall(vim.api.nvim_buf_delete, created_buf, { force = true })
    end
    util.notify(
      "Failed to open prompt file " .. path .. ": " .. reason,
      vim.log.levels.ERROR
    )
    return nil
  end

  -- In-place mount: origin was not protected, or was a fullscreen YAPT
  -- terminal whose restored window can take the prompt (must_split false).
  -- Destination checks use window_accepts_prompt (file with winfix/preview
  -- allowed): do not re-apply the origin denylist after hide or on a
  -- split/tab the plugin just created (WinNew may pin the new window).
  -- ensure_normal_edit_window already upgraded must_split when hide
  -- restored a winfix sidebar or winfixbuf window, so those still split
  -- instead of aborting. Explicit <C-x>/<C-v>/<C-t> and a protected
  -- origin still split/tab.
  if open_cmd == "tabedit" then
    -- :tabnew as-is: do not switch to a mount window first (origin-tab
    -- teardown was skipped; a new tab must not split nvim-tree / a
    -- terminal in the origin tab).
    local origin = vim.api.nvim_get_current_win()
    local ok, err = pcall(vim.cmd, "tabnew")
    if not ok then
      return abort_open(tostring(err))
    end
    local new_win = vim.api.nvim_get_current_win()
    if new_win ~= origin then
      leftover_win = new_win
    end
  elseif open_cmd == "new" or open_cmd == "vnew" or must_split then
    -- <C-x> / <C-v> share Enter's split: do not :new / :vnew in a
    -- protected window (terminal, sidebar, leftover float) after the
    -- picker. must_split: origin was protected *before* hide, or hide
    -- restored a winfix sidebar / winfixbuf window. After hide the
    -- restored file can look like a mount; still split. False after a
    -- fullscreen-terminal origin whose restored window can take the
    -- prompt: mount there.
    local split = open_edit_split(open_cmd == "vnew")
    if not split then
      return abort_open("no suitable window to edit in")
    end
    leftover_win = split
    pcall(vim.api.nvim_set_current_win, split)
  end

  local win = vim.api.nvim_get_current_win()
  if util.is_float_window(win) then
    return abort_open("refusing to edit in a floating window")
  end
  if not window_accepts_prompt(win) then
    return abort_open("no suitable window to edit in")
  end

  local placeholder = vim.api.nvim_win_get_buf(win)
  -- Do not bufadd/bufload into a loaded buffer that already has this name
  -- (unsaved :PTPrompt in the same clock second): bump _1, _2, ... first.
  local resolved = avoid_loaded_history_buffer(path)
  if not resolved or loaded_buffer_with_path(resolved) then
    return abort_open("history path is in use by a loaded buffer")
  end
  path = resolved
  local preexisting = buffer_with_path(path)
  local buf = vim.fn.bufadd(path)
  if not buf or buf == 0 then
    return abort_open("bufadd failed")
  end
  vim.bo[buf].buflisted = true
  if not vim.api.nvim_buf_is_loaded(buf) then
    pcall(vim.fn.bufload, buf)
  end

  local created = preexisting == nil
  -- bufload fires BufNew / BufRead / FileType; a markdown hook may steal
  -- the current window (Reader, outline, preview, wincmd). Mount into `win`.
  if util.is_float_window(win) then
    return abort_open("refusing to edit in a floating window", created and buf or nil)
  end
  if not window_accepts_prompt(win) then
    return abort_open("no suitable window to edit in", created and buf or nil)
  end

  -- Strip preview UI before set_buf so BufWinEnter does not see the
  -- prompt as a preview buffer. Restore on failure so a failed mount
  -- does not leave :pedit without 'previewwindow'. After success, strip
  -- again (WinNew / FileType may have set the flag on a new split/tab).
  local was_preview = vim.wo[win].previewwindow
  local preview_winfixheight = vim.wo[win].winfixheight
  clear_preview_destination(win)

  local ok, err = pcall(vim.api.nvim_win_set_buf, win, buf)
  if not ok then
    -- 'hidden' off + modified buffer in `win` (E37): hide from that window.
    ok, err = pcall(vim.api.nvim_win_call, win, function()
      vim.cmd("hide buffer " .. buf)
    end)
  end
  if not ok then
    if was_preview and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_set_option_value, "previewwindow", true, { win = win })
      pcall(
        vim.api.nvim_set_option_value,
        "winfixheight",
        preview_winfixheight,
        { win = win }
      )
    end
    return abort_open(tostring(err), created and buf or nil)
  end
  pcall(vim.api.nvim_set_current_win, win)
  clear_preview_destination(win)

  if placeholder ~= buf then
    wipe_orphaned_placeholder(placeholder)
  end
  return path
end

-- Create a new prompt file in history dir and open it in a non-float window.
-- @param config Plugin config (must have history.dir)
-- @param opts table|nil { lines = string[], location = resolve_file_location(),
--   open_cmd = nil|"new"|"vnew"|"tabedit",
--   must_split = boolean|nil origin mount snapshot from picker-open }
-- @return string|nil full path of the created file, or nil on failure
function M.create_prompt_file(config, opts)
  config = config or {}
  opts = opts or {}
  local fullpath
  if opts.lines then
    fullpath = M.write_prompt_file(config, opts.lines)
    if not fullpath then
      return nil
    end
  else
    local dir = ensure_history_dir(config)
    if not dir then
      return nil
    end
    fullpath = unique_history_path(dir)
  end
  -- File is already on disk when opts.lines is set; never delete it if
  -- opening fails (E37 with 'hidden' off, user aborting 'confirm', etc.).
  local opened = open_prompt_path(fullpath, opts.location, opts.open_cmd, opts.must_split)
  if not opened then
    return nil
  end
  util.notify("Created " .. opened, vim.log.levels.INFO)
  return opened
end

local function current_buffer_text(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local text = table.concat(lines, "\n")
  if text == "" then
    return "\n"
  end
  return text .. "\n"
end

-- Send buffered text to whichever terminal is currently active and report success.
-- @param view_buf integer|nil visible buffer for close-after-send window swap
-- @param on_success function|nil called after terminal.send_text returns true.
--   Return false to skip the success notify (hook already reported failure).
--   Return a string to append to the success message (e.g. a saved history path).
local function send_to_active_terminal(text, source_buf, config, success_message, target_id, view_buf, on_success)
  local active_id = target_id or tabs.get_active()
  if not active_id then
    return
  end
  -- Let send_text warn if the job is dead (do not swallow "Terminal is not running").
  local sent = terminal.send_text(text, active_id)
  if sent then
    local show_success = true
    local extra
    if on_success then
      local hook_ok, hook_result = pcall(on_success)
      if not hook_ok then
        show_success = false
        util.notify("Sent to terminal, but failed afterwards: " .. tostring(hook_result), vim.log.levels.ERROR)
      elseif hook_result == false then
        show_success = false
      elseif type(hook_result) == "string" and hook_result ~= "" then
        extra = hook_result
      end
    end
    if show_success then
      local msg = success_message or "Sent current file contents to terminal"
      if extra then
        msg = msg .. " (" .. extra .. ")"
      end
      util.notify(msg, vim.log.levels.INFO)
    end
    close_sent_prompt_buffer_if_needed(source_buf, config, view_buf)
  end
end

-- Create a fresh terminal (via picker) and send `text` to it once it boots.
-- @param display_mode string|nil "split" (default) or "fullscreen"
-- @param name string|nil optional terminal name
-- @param view_buf integer|nil visible buffer for fullscreen prepare / close-after-send
-- @param on_success function|nil called after terminal.send_text returns true
local function pick_create_and_send(config, text, source_buf, success_message, display_mode, name, view_buf, on_success)
  picker.pick_command(config, function(cmd)
    if not cmd then return end
    if display_mode == "fullscreen" then
      prepare_prompt_buffer_for_fullscreen(source_buf, config, view_buf)
      -- Prepare already tore down / swapped the view; ignore for deferred close.
      view_buf = source_buf
    end

    tabs.create_terminal(name, config, cmd, display_mode)
    vim.defer_fn(function()
      send_to_active_terminal(text, source_buf, config, success_message, nil, view_buf, on_success)
    end, 200)
  end)
end

-- Read current buffer text for send, with optional soft mode.
-- Soft mode: no warnings; returns nil when empty or non-file (used by create-maybe-send).
-- Strict mode: warns and aborts on non-file or empty buffers (used by :PTSend).
-- Unnamed buffers with content are persisted to prompt history first.
-- Resolves virtual views (e.g. markdown-table-wrap Reader) to the Source buffer
-- so buftype/path/content come from the real file, not the rendered scratch.
-- Also returns view_bufnr so close/fullscreen can swap the visible window.
-- @param config Plugin config
-- @param opts table|nil { soft = boolean }
-- @return source_buf, text, view_buf  or nil, nil, nil when there is nothing sendable
local function current_file_text(config, opts)
  opts = opts or {}
  local soft = opts.soft == true
  local loc = util.resolve_file_location()
  local buf = loc.source_bufnr
  local view_buf = loc.view_bufnr

  if vim.bo[buf].buftype ~= "" then
    if not soft then
      util.notify("Current buffer is not a normal file buffer", vim.log.levels.WARN)
    end
    return nil, nil, nil
  end

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if vim.trim(table.concat(lines, "\n")) == "" then
    if not soft then
      util.notify("Current buffer is empty — nothing to send", vim.log.levels.WARN)
    end
    return nil, nil, nil
  end

  local path = loc.path
  if path == nil or path == "" then
    local new_path = persist_unnamed_buffer_to_history(buf, lines, config)
    if not new_path then
      return nil, nil, nil
    end
    util.notify("Saved new buffer as " .. new_path, vim.log.levels.INFO)
    return buf, table.concat(lines, "\n") .. "\n", view_buf
  end

  if vim.bo[buf].modified then
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("write")
    end)
  end
  return buf, current_buffer_text(buf), view_buf
end

-- Show the last terminal (or create one) and send `text`.
-- source_buf/view_buf drive close-after-send; pass nil to leave the current buffer.
-- @param on_success function|nil called after terminal.send_text returns true
local function show_and_send(config, text, source_buf, view_buf, success_message, on_success)
  if not tabs.has_terminals() then
    pick_create_and_send(config, text, source_buf, success_message, nil, nil, view_buf, on_success)
    return
  end

  local last_id = tabs.get_last()
  if not last_id then
    pick_create_and_send(config, text, source_buf, success_message, nil, nil, view_buf, on_success)
    return
  end

  local term_meta = tabs.get_terminal(last_id)
  local stored_cmd = term_meta and term_meta.command

  -- Tab-local visibility: show/rehome when not in this tabpage; force-insert for send.
  if not terminal.is_visible(last_id) then
    terminal.show_in_preferred_mode(config, last_id, stored_cmd)
  else
    terminal.apply_ui_state(last_id, { force_insert = true })
  end

  vim.defer_fn(function()
    send_to_active_terminal(text, source_buf, config, success_message, last_id, view_buf, on_success)
  end, 100)
end

-- Send current buffer's file contents to the active terminal.
-- Ensures at least one terminal exists and shows it (in its preferred
-- display mode, so a fullscreen terminal stays fullscreen), then sends the text.
-- Saves the current buffer if modified so the file exists on disk for the CLI.
-- @param config Plugin config (for terminal/tabs)
function M.send_prompt_file_to_terminal(config)
  local source_buf, text_to_send, view_buf = current_file_text(config)
  if not source_buf then
    return
  end
  show_and_send(config, text_to_send, source_buf, view_buf, nil)
end

-- Send arbitrary text to the last/created terminal without treating the
-- current buffer as a prompt file (no close-after-send).
-- @param config Plugin config
-- @param text string
-- @param opts table|nil { success_message = string, on_success = function }
--   on_success: return false to skip the success notify; return a string to
--   append to it (e.g. a saved history path).
function M.send_text_to_terminal(config, text, opts)
  opts = opts or {}
  if not text or vim.trim(text) == "" then
    util.notify("Nothing to send", vim.log.levels.WARN)
    return
  end
  if not text:match("\n$") then
    text = text .. "\n"
  end
  show_and_send(config, text, nil, nil, opts.success_message or "Sent text to terminal", opts.on_success)
end

-- Send current buffer's file contents to the active terminal, forcing fullscreen display.
-- Like send_prompt_file_to_terminal, but always shows the terminal in fullscreen
-- (promoting from split if needed) before sending.
-- Saves the current buffer if modified so the file exists on disk for the CLI.
-- @param config Plugin config (for terminal/tabs)
function M.send_prompt_file_to_terminal_fullscreen(config)
  local source_buf, text_to_send, view_buf = current_file_text(config)
  if not source_buf then
    return
  end

  if not tabs.has_terminals() then
    pick_create_and_send(config, text_to_send, source_buf, nil, "fullscreen", nil, view_buf)
    return
  end

  local last_id = tabs.get_last()
  if not last_id then
    pick_create_and_send(config, text_to_send, source_buf, nil, "fullscreen", nil, view_buf)
    return
  end

  local term_meta = tabs.get_terminal(last_id)
  local stored_cmd = term_meta and term_meta.command

  if terminal.is_fullscreen_active(last_id) then
    if terminal.is_visible(last_id) then
      terminal.apply_ui_state(last_id, { force_insert = true })
    else
      -- Fullscreen only in another tabpage: rehome here (do not jump tabs).
      terminal.show_in_preferred_mode(config, last_id, stored_cmd)
    end
  else
    prepare_prompt_buffer_for_fullscreen(source_buf, config, view_buf)
    -- Prepare already tore down / swapped the view; ignore for deferred close.
    view_buf = source_buf

    terminal.toggle_fullscreen(config, last_id, stored_cmd, { force_insert = true })
  end

  vim.defer_fn(function()
    send_to_active_terminal(text_to_send, source_buf, config, nil, last_id, view_buf)
  end, 100)
end

-- Always create a new terminal session. If the current buffer has sendable
-- content, send it after the terminal boots; otherwise only create.
-- @param config Plugin config
-- @param opts table|nil { display_mode = "split"|"fullscreen", name = string|nil }
function M.create_terminal_maybe_send(config, opts)
  opts = opts or {}
  local display_mode = opts.display_mode or "split"
  local name = opts.name

  local source_buf, text_to_send, view_buf = current_file_text(config, { soft = true })
  if source_buf and text_to_send then
    pick_create_and_send(
      config,
      text_to_send,
      source_buf,
      "Sent current file contents to new terminal",
      display_mode,
      name,
      view_buf
    )
    return
  end

  picker.pick_command(config, function(cmd)
    if not cmd then return end
    tabs.create_terminal(name, config, cmd, display_mode)
  end)
end

-- Return full path of the most recent prompt file in history (by timestamp in filename).
-- Returns nil if directory does not exist or has no .md files.
function M.get_last_prompt_file(config)
  config = config or {}
  local dir = history_dir_path(config)
  if vim.fn.isdirectory(dir) ~= 1 then
    return nil
  end
  local files = vim.fn.readdir(dir)
  local md_files = {}
  for _, f in ipairs(files) do
    if f:match("%.md$") then
      table.insert(md_files, f)
    end
  end
  if #md_files == 0 then
    return nil
  end
  table.sort(md_files, function(a, b)
    return a > b
  end)
  return dir .. "/" .. md_files[1]
end

-- Open history directory in Telescope (find_files with cwd = history dir).
-- No-op with a warning if Telescope is not available.
function M.open_history_in_telescope(config)
  local ok = pcall(require, "telescope")
  if not ok then
    util.notify("telescope.nvim is required for PTHistory", vim.log.levels.WARN)
    return
  end

  local entries, dir = list_history_files_sorted(config)
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

  local results = {}
  for _, e in ipairs(entries) do
    table.insert(results, e.name)
  end

  local entry_maker = make_entry.gen_from_file({
    cwd = dir,
  })

  local chronological_sorter = util.chronological_sorter(conf.file_sorter({}))

  local history_previewer = previewers.new_buffer_previewer({
    title = "Prompt preview",
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
    prompt_title = "Prompt history",
    finder = finders.new_table({
      results = results,
      entry_maker = entry_maker,
    }),
    sorter = chronological_sorter,
    tiebreak = function()
      return false
    end,
    previewer = history_previewer,
    attach_mappings = function(prompt_bufnr, map)
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

-- Open or switch to the buffer of the last prompt file from history.
function M.open_last_prompt_buffer(config)
  local path = M.get_last_prompt_file(config)
  if not path then
    util.notify("No prompt files in history", vim.log.levels.WARN)
    return
  end
  local buf = vim.fn.bufadd(path)
  if vim.api.nvim_buf_is_loaded(buf) then
    vim.api.nvim_set_current_buf(buf)
  else
    vim.cmd("edit " .. vim.fn.fnameescape(path))
  end
end

return M
