-- Terminal management for yapt.nvim plugin
--
-- This module handles the low-level terminal operations:
-- - Creating terminal buffers and windows
-- - Managing terminal visibility (show/hide) for both split and fullscreen modes
-- - Sending text to terminal buffers
-- - Terminal lifecycle (on_exit callbacks)
-- - Terminal mode keybindings (configured by user)
--
-- Architecture:
-- - Stores terminal instances with buffers, windows, job IDs, and last
--   used display_mode ("split" | "fullscreen")
-- - Supports multiple terminals with unique IDs
-- - Tracks at most one fullscreen terminal at a time (singleton state)
-- - Cleanup callbacks notify tabs.lua when terminals exit
--
local config_module = require("yapt.config")
local util = require("yapt.util")

local M = {}

-- State tracking for multiple terminals
local terminals = {}  -- Table of terminal instances keyed by ID
local active_id = nil  -- Currently active terminal ID
local default_id = "default"  -- Default terminal ID for backward compatibility
local cleanup_callbacks = {}  -- Callbacks called when a terminal exits (used by tabs.lua)

local forward_seqs = {}
local forward_seq_counter = 0

local special_key_defs = {
  {"<Up>",       "\x1b[A"},
  {"<Down>",     "\x1b[B"},
  {"<Right>",    "\x1b[C"},
  {"<Left>",     "\x1b[D"},
  {"<PageUp>",   "\x1b[5~"},
  {"<PageDown>", "\x1b[6~"},
  {"<Home>",     "\x1b[H"},
  {"<End>",      "\x1b[F"},
  {"<Insert>",   "\x1b[2~"},
  {"<Delete>",   "\x1b[3~"},
  {"<F1>",       "\x1bOP"},
  {"<F2>",       "\x1bOQ"},
  {"<F3>",       "\x1bOR"},
  {"<F4>",       "\x1bOS"},
  {"<F5>",       "\x1b[15~"},
  {"<F6>",       "\x1b[17~"},
  {"<F7>",       "\x1b[18~"},
  {"<F8>",       "\x1b[19~"},
  {"<F9>",       "\x1b[20~"},
  {"<F10>",      "\x1b[21~"},
  {"<F11>",      "\x1b[23~"},
  {"<F12>",      "\x1b[24~"},
  {"<Tab>",      "\x09"},
  {"<BS>",       "\x7f"},
  {"<CR>",       "\x0d"},
  {"<S-Up>",     "\x1b[1;2A"},
  {"<S-Down>",   "\x1b[1;2B"},
  {"<S-Right>",  "\x1b[1;2C"},
  {"<S-Left>",   "\x1b[1;2D"},
  {"<S-PageUp>",   "\x1b[5;2~"},
  {"<S-PageDown>", "\x1b[6;2~"},
  {"<S-Home>",     "\x1b[1;2H"},
  {"<S-End>",      "\x1b[1;2F"},
  {"<C-Up>",     "\x1b[1;5A"},
  {"<C-Down>",   "\x1b[1;5B"},
  {"<C-Right>",  "\x1b[1;5C"},
  {"<C-Left>",   "\x1b[1;5D"},
  {"<S-Tab>",    "\x1b[Z"},
  {"<Space>",    " "},
  {"<C-M-u>",    "\x1b\x15"},
  {"<C-M-d>",    "\x1b\x04"},
}

local special_key_map = nil

local function get_special_key_map()
  if special_key_map then return special_key_map end
  special_key_map = {}
  for _, pair in ipairs(special_key_defs) do
    local nvim_key = vim.api.nvim_replace_termcodes(pair[1], true, false, true)
    special_key_map[nvim_key] = pair[2]
  end
  return special_key_map
end

local function id_for_buf(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end
  for id, term in pairs(terminals) do
    if term.buf == buf then
      return id
    end
  end
  return nil
end

local function get_job_id_for_current_buf()
  local buf = vim.api.nvim_get_current_buf()
  if vim.bo[buf].buftype ~= "terminal" then return nil end
  local job_id = vim.b[buf].terminal_job_id
  if job_id then return job_id end
  for _, term in pairs(terminals) do
    if term.buf == buf and term.job_id then
      return term.job_id
    end
  end
  return nil
end

local function neovim_key_to_termseq(key)
  if #key == 1 then
    local b = string.byte(key)
    if b == 27 then return nil end
    return key
  end
  local kmap = get_special_key_map()
  if kmap[key] then return kmap[key] end
  return key
end

local function do_send_key(key)
  local seq = neovim_key_to_termseq(key)
  if not seq then return false end
  local job_id = get_job_id_for_current_buf()
  if not job_id then return false end
  vim.api.nvim_chan_send(job_id, seq)
  return true
end

-- Fullscreen mode singleton state.
-- At most one terminal can be displayed fullscreen at a time because
-- "fullscreen" simply means "took over a window that was showing something
-- else". The saved_win/saved_buf pair lets us hand the window back.
local fullscreen_state = {
  active = false,       -- True while a terminal is mounted in saved_win
  terminal_id = nil,    -- ID of the terminal mounted fullscreen
  saved_win = nil,      -- Window we took over
  saved_buf = nil,      -- Buffer that was in saved_win before we took over
}

local function reset_fullscreen_state()
  fullscreen_state.active = false
  fullscreen_state.terminal_id = nil
  fullscreen_state.saved_win = nil
  fullscreen_state.saved_buf = nil
end

local function get_terminal(id)
  id = id or active_id or default_id
  return terminals[id]
end

local function is_win_displayed(win)
  return win ~= nil
    and vim.api.nvim_win_is_valid(win)
    and vim.fn.win_id2win(win) ~= 0
end

local function is_visible(id)
  local term = get_terminal(id)
  if not term then return false end
  return is_win_displayed(term.win)
end

local function is_buffer_valid(id)
  local term = get_terminal(id)
  if not term then return false end
  return term.buf ~= nil and vim.api.nvim_buf_is_valid(term.buf)
end

-- Per-terminal UI state: last known focus mode ("t" = terminal-job / insert,
-- "n" = normal) and winsaveview snapshot for scroll restoration.
local function ensure_ui_state(term)
  if not term.ui_state then
    term.ui_state = { mode = "t", view = nil }
  end
  return term.ui_state
end

-- Neovim tails a terminal window, focused or not, only while its cursor is on
-- the last buffer line. <C-\><C-n> parks the cursor on the TUI row instead.
local function cursor_on_last_line(win, buf)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return false
  end
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return false
  end
  local ok, pos = pcall(vim.api.nvim_win_get_cursor, win)
  if not ok or not pos then
    return false
  end
  return pos[1] == vim.api.nvim_buf_line_count(buf)
end

local function pin_cursor_to_end(win, buf)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local last = vim.api.nvim_buf_line_count(buf)
  if last < 1 then
    return
  end
  -- Already on the last line: keep the column. Job mode still moves here
  -- when the cursor is sitting on the TUI row above the end.
  if cursor_on_last_line(win, buf) then
    return
  end
  -- Clamped to the last byte, so the end of a long line stays in view.
  pcall(vim.api.nvim_win_set_cursor, win, { last, vim.v.maxcol })
end

-- Suppress TermLeave mode overwrites while hide() is tearing down the window.
local hiding_terminal = false

-- True while unfocus() is leaving terminal-job mode and pinning the cursor.
-- stopinsert moves the cursor onto the TUI row before we pin it to the end;
-- that intermediate CursorMoved must not end follow.
local unfocusing = false

-- Extra-split unfocus only. stopinsert then switches to another window of
-- this same buffer, so ModeChanged and TermLeave both run here and would
-- otherwise record the tracked window as a normal-mode leave. Cleared on
-- the next tick: the other event in this turn still has to see it.
-- Tracked-window unfocus does not set this.
local function mark_unfocus_leave_skip(term)
  term._skip_unfocus_leave = {}
end

local function take_unfocus_leave_skip(term)
  local mark = term and term._skip_unfocus_leave
  if not mark then
    return false
  end
  vim.schedule(function()
    if term._skip_unfocus_leave == mark then
      term._skip_unfocus_leave = nil
    end
  end)
  return true
end

-- Same-buffer destination of a job-mode unfocus. terminal_check_cursor()
-- parks that window on the TUI row before TermLeave; TermLeave puts the view
-- back. A normal-mode unfocus does not set this, because it never runs
-- TermLeave and a leftover stash would hide scrolls on term.win forever.
local function unfocus_dest_restore_pending(term, win)
  local pending = term and term._unfocus_dest_restore
  return pending ~= nil and win ~= nil and pending.win == win
end

local function restore_unfocus_dest(term)
  local pending = term and term._unfocus_dest_restore
  if not pending then
    return
  end
  local win = pending.win
  local view = pending.view
  if view and win and vim.api.nvim_win_is_valid(win)
    and term.buf and vim.api.nvim_buf_is_valid(term.buf)
    and vim.api.nvim_win_get_buf(win) == term.buf then
    -- Keep the stash set across winrestview so a scroll autocmd fired from
    -- the restore still sees the TUI-row jump as not a user scroll.
    pcall(vim.api.nvim_win_call, win, function()
      pcall(vim.fn.winrestview, view)
    end)
  end
  if term._unfocus_dest_restore == pending then
    term._unfocus_dest_restore = nil
  end
end

-- Buffer that entered terminal-job mode (TermEnter, or ModeChanged into "t").
-- A terminal <Cmd> map that stopinserts and then switches windows stays in
-- "t" until the map returns. TermLeave and ModeChanged (t → nt) then both run
-- on the destination buffer, in that same turn, before vim.schedule.
-- ui state for the leave is written only when this callback's buffer is the
-- one recorded here. Do not clear the record from a non-owner, and do not
-- clear it synchronously: the other event still has to see it.
local terminal_job_buf = nil
local terminal_job_gen = 0

local function remember_terminal_job(buf)
  terminal_job_gen = terminal_job_gen + 1
  terminal_job_buf = buf
end

local function terminal_job_owned_by(buf)
  return buf ~= nil and terminal_job_buf == buf
end

-- Deferred so the other leave event in this turn still sees the owner.
-- A newer TermEnter bumps the generation and must not be cleared.
local function clear_terminal_job_buf(buf)
  local gen = terminal_job_gen
  vim.schedule(function()
    if terminal_job_buf == buf and terminal_job_gen == gen then
      terminal_job_buf = nil
    end
  end)
end

local function in_terminal_win(win)
  return win
    and vim.api.nvim_win_is_valid(win)
    and vim.api.nvim_get_current_win() == win
end

local function with_hiding_terminal(fn)
  hiding_terminal = true
  local ok, err = pcall(fn)
  hiding_terminal = false
  if not ok then
    error(err)
  end
end

-- Suppress WinEnter view restore while apply_ui_state focuses the window
-- (avoids a nested restore that would defeat restore_view = false).
local applying_ui_state = false

local function with_applying_ui_state(fn)
  applying_ui_state = true
  local ok, err = pcall(fn)
  applying_ui_state = false
  if not ok then
    error(err)
  end
end

-- Capture winsaveview from any valid window (including other tabpages).
local function capture_view(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return nil
  end
  return vim.api.nvim_win_call(win, function()
    return vim.fn.winsaveview()
  end)
end

local function save_ui_state(id, mode_override)
  local term = get_terminal(id)
  if not term then return end
  local ui = ensure_ui_state(term)

  -- Follow owns the live cursor. Skip winsaveview so a hide does not freeze
  -- the tail. An explicit "t" or "n" still applies: fullscreen toggle and
  -- switch_to save that mode before hide. hide() itself passes nil instead
  -- of the normal-mode hide map's "n", so dismiss does not replace a stored
  -- "t".
  if term._keep_follow then
    if mode_override == "t" or mode_override == "n" then
      ui.mode = mode_override
    end
    return
  end

  if mode_override == "t" or mode_override == "n" then
    ui.mode = mode_override
  elseif is_win_displayed(term.win) and vim.api.nvim_get_current_win() == term.win then
    local m = vim.api.nvim_get_mode().mode
    ui.mode = (m == "t") and "t" or "n"
  end

  local view = capture_view(term.win)
  if view then
    ui.view = view
  end
end

local function clamp_view(view, buf)
  local last = vim.api.nvim_buf_line_count(buf)
  local clamped = vim.deepcopy(view)
  clamped.lnum = math.max(1, math.min(clamped.lnum or last, last))
  clamped.col = math.max(0, clamped.col or 0)
  local line = vim.api.nvim_buf_get_lines(buf, clamped.lnum - 1, clamped.lnum, false)[1] or ""
  clamped.col = math.min(clamped.col, #line)
  return clamped
end

-- Clamp lnum/col to the buffer, then winrestview. No-op when gen is stale or
-- win gone. Returns the clamped view that was applied (or nil).
local function restore_normal_view(term, view, gen)
  if not view or not term or not is_win_displayed(term.win) then
    return nil
  end
  if gen and term._ui_apply_gen ~= gen then
    return nil
  end
  local clamped
  -- Late BufEnter startinsert may have put us back in job mode; leave it
  -- before restoring or the terminal job cursor wins. Mode "t" is global:
  -- only this window's job may be stopped.
  if vim.api.nvim_get_mode().mode == "t" and in_terminal_win(term.win) then
    vim.cmd("stopinsert")
  end
  vim.api.nvim_win_call(term.win, function()
    clamped = clamp_view(view, 0)
    pcall(vim.fn.winrestview, clamped)
  end)
  return clamped
end

-- True while apply_ui_state owns focus/restore for this terminal. Blocks
-- deferred WinEnter restores from show()/set_current_win (including the
-- restore_view = false picker/refocus paths).
local function suppress_winenter_restore(term)
  return term._suppress_winenter_restore == true
end

local function begin_ui_apply(term)
  term._suppress_winenter_restore = true
  term._ui_apply_pending = true
  term._ui_apply_gen = (term._ui_apply_gen or 0) + 1
  return term._ui_apply_gen
end

-- Bumped when a follow-pin retry loop must not stopinsert. Deferred
-- callbacks captured the previous value and return before touching mode.
local function invalidate_follow_pin_retry(term)
  term._follow_pin_token = (term._follow_pin_token or 0) + 1
end

local function finish_ui_apply(term, gen)
  if term._ui_apply_gen ~= gen then
    return
  end
  if term._view_restore_gen == gen then
    term._view_restore_gen = nil
  end
  if term._follow_pin_gen == gen then
    term._follow_pin_gen = nil
  end
  -- TermLeave clears this only when it runs on the owner. A window switch
  -- delivers that event to the destination, which returns first. Drop the
  -- flag here so a later scroll can still end follow.
  term._follow_pinning = nil
  term._ui_apply_pending = false
  term._suppress_winenter_restore = false
  invalidate_follow_pin_retry(term)
end

-- Remount can fire BufEnter/startinsert/TermEnter and clobber ui_state before
-- apply_ui_state runs. Snapshot mode/view onto the term so apply can re-apply
-- the intent even if TermEnter races between show and apply.
local function with_preserved_ui_intent(term, fn)
  local ui = ensure_ui_state(term)
  local mode = ui.mode
  local view = ui.view and vim.deepcopy(ui.view) or nil
  term._suppress_winenter_restore = true
  term._preserved_ui = { mode = mode, view = view }
  local ok, err = pcall(fn)
  if term.ui_state then
    term.ui_state.mode = mode
    if view then
      term.ui_state.view = view
    end
  end
  -- Keep suppress until apply finishes. Bare M.show clears on next tick.
  vim.schedule(function()
    if term._preserved_ui then
      term._preserved_ui = nil
    end
    if not term._ui_apply_pending then
      term._suppress_winenter_restore = false
    end
  end)
  if not ok then
    error(err)
  end
end

-- If show() stashed intent, re-apply it before reading mode/view for restore.
local function take_preserved_ui(term)
  local pending = term._preserved_ui
  term._preserved_ui = nil
  if not pending or not term.ui_state then
    return
  end
  if pending.mode == "t" or pending.mode == "n" then
    term.ui_state.mode = pending.mode
  end
  if pending.view then
    term.ui_state.view = pending.view
  end
end

-- Re-assert normal-mode view across remount/resize/startinsert races.
-- Retries beat deferred BufEnter startinsert and SIGWINCH redraws.
local function schedule_normal_view_restore(term, view, gen)
  term._view_restore_gen = gen
  local delays_ms = { 0, 20, 50, 120 }
  local remaining = #delays_ms

  local function apply_once()
    if term._ui_apply_gen ~= gen or not is_win_displayed(term.win) then
      return false
    end
    local ok, err = pcall(function()
      with_applying_ui_state(function()
        vim.api.nvim_set_current_win(term.win)
        local applied = restore_normal_view(term, view, gen)
        if term._ui_apply_gen == gen and term.ui_state then
          term.ui_state.mode = "n"
          if applied then
            term.ui_state.view = applied
          end
        end
      end)
    end)
    if not ok then
      error(err)
    end
    return true
  end

  for _, delay in ipairs(delays_ms) do
    vim.defer_fn(function()
      remaining = remaining - 1
      if term._ui_apply_gen == gen then
        apply_once()
      end
      if remaining <= 0 then
        finish_ui_apply(term, gen)
      end
    end, delay)
  end
end

-- Pin has stuck: cursor is on the last line and this window is not in
-- terminal-job mode. A later TermEnter is the user.
local function follow_pin_stuck(term)
  if not term or not term._keep_follow or not is_win_displayed(term.win) then
    return false
  end
  if vim.api.nvim_get_mode().mode == "t" and in_terminal_win(term.win) then
    return false
  end
  return cursor_on_last_line(term.win, term.buf)
end

-- Drop the apply guards once the tail is pinned. Do not set _keep_follow.
-- Invalidates the retry token so a later timer cannot stopinsert a real
-- TermEnter. _keep_follow stays set; that TermEnter clears it.
local function complete_follow_pin(term, gen)
  if not follow_pin_stuck(term) then
    return false
  end
  term._follow_pinning = nil
  if term.ui_state then
    term.ui_state.mode = "n"
  end
  invalidate_follow_pin_retry(term)
  finish_ui_apply(term, gen)
  return true
end

-- stopinsert from a timer only sets a flag until terminal_enter() unwinds.
-- terminal_check_cursor() then parks the cursor on the TUI row, and only a
-- synchronous pin in the owner buffer's TermLeave sticks. A scroll that
-- cleared _keep_follow must not pin or set the flag again.
local function reassert_follow_cursor(term, gen)
  if term._ui_apply_gen ~= gen or not term._keep_follow or not is_win_displayed(term.win) then
    return
  end
  if follow_pin_stuck(term) then
    complete_follow_pin(term, gen)
    return
  end
  -- Only this window's job. Another terminal's mode must not be stopped.
  if vim.api.nvim_get_mode().mode == "t" and in_terminal_win(term.win) then
    -- Set before stopinsert. CursorMoved sees the TUI-row jump before TermLeave.
    term._follow_pinning = true
    local stopped, stop_err = pcall(vim.cmd, "stopinsert")
    if not stopped then
      term._follow_pinning = nil
      error(stop_err)
    end
    return
  end
  if not term._keep_follow then
    return
  end
  -- Do not finish here. The caller retries only while the tail is not pinned
  -- yet. Once this pin sticks, that caller must not arm another stopinsert loop.
  pin_cursor_to_end(term.win, term.buf)
end

-- Re-pin a normal-mode follow across a deferred BufEnter startinsert.
-- Retries cover a job-mode exit that has not pinned yet. Once the cursor is
-- on the last line and this window is not in terminal-job mode, stop:
-- finish the apply so a later TermEnter is the user and is not stopinsert'd.
-- A scroll that cleared _keep_follow is left alone.
-- Do not call this after the pin has already stuck. complete_follow_pin /
-- finish_ui_apply bump _follow_pin_token; a stale callback returns before
-- stopinsert.
local function schedule_follow_pin(term, gen)
  invalidate_follow_pin_retry(term)
  local token = term._follow_pin_token
  term._view_restore_gen = gen
  term._follow_pin_gen = gen
  local delays_ms = { 0, 20, 50, 120 }
  local remaining = #delays_ms

  local function apply_once()
    if term._follow_pin_token ~= token then
      return false
    end
    if term._ui_apply_gen ~= gen or not is_win_displayed(term.win) then
      return false
    end
    local ok, err = pcall(function()
      with_applying_ui_state(function()
        if term._follow_pin_token ~= token then
          return
        end
        if not term._keep_follow then
          finish_ui_apply(term, gen)
          return
        end
        if follow_pin_stuck(term) then
          complete_follow_pin(term, gen)
          return
        end
        reassert_follow_cursor(term, gen)
        if term._follow_pin_token ~= token then
          return
        end
        if follow_pin_stuck(term) then
          complete_follow_pin(term, gen)
          return
        end
        if term._keep_follow and term.ui_state then
          term.ui_state.mode = "n"
        end
      end)
    end)
    if not ok then
      error(err)
    end
    return true
  end

  for _, delay in ipairs(delays_ms) do
    vim.defer_fn(function()
      -- Token check is first: a pin that already stuck must not stopinsert.
      if term._follow_pin_token ~= token then
        return
      end
      remaining = remaining - 1
      if term._ui_apply_gen == gen then
        apply_once()
      end
      if term._follow_pin_token ~= token then
        return
      end
      if remaining <= 0 then
        if term._follow_pinning then
          -- stopinsert only sets a flag until terminal_enter unwinds.
          -- This callback is a K_EVENT, and state_handle_k_event drains
          -- vim.schedule before that return, so a scheduled finish would
          -- clear _follow_pin_gen before TermLeave can pin.
          -- defer_fn(0) runs on a later loop tick, after TermLeave.
          -- complete_follow_pin finishes a pin that stuck and bumps the
          -- token. If this window is still in job mode, TermLeave has not
          -- run: defer again instead of clearing _follow_pin_gen. If the
          -- pin never sticks, finish this generation so _view_restore_gen
          -- cannot stay set. A newer apply has a different gen.
          -- While mode stays "t", defer a handful of times, then finish
          -- this generation anyway so a later TermEnter is the user.
          local deferrals_left = 8
          local function finish_pinned_apply()
            if term._follow_pin_token ~= token or term._ui_apply_gen ~= gen then
              return
            end
            if deferrals_left > 0
              and vim.api.nvim_get_mode().mode == "t"
              and in_terminal_win(term.win) then
              deferrals_left = deferrals_left - 1
              vim.defer_fn(finish_pinned_apply, 0)
              return
            end
            finish_ui_apply(term, gen)
          end
          vim.defer_fn(finish_pinned_apply, 0)
        else
          finish_ui_apply(term, gen)
        end
      end
    end, delay)
  end
end

-- Restore or force-insert after a terminal window is shown.
-- opts.force_insert: always enter terminal-job mode (send/paste paths).
-- opts.restore_view: when restoring normal mode, apply winsaveview (default true).
--   Set false when refocusing an already-visible window so live scroll is kept
--   (also skips the job-mode jump-to-EOF).
local function apply_ui_state(id, opts)
  opts = opts or {}
  local term = get_terminal(id)
  if not term or not is_win_displayed(term.win) then
    return
  end

  -- Re-apply intent saved around show()/set_buf before TermEnter can stick.
  take_preserved_ui(term)

  local force_insert = opts.force_insert == true
  local restore_view = opts.restore_view ~= false
  local ui = term.ui_state
  -- _keep_follow means the cursor stays on the last line, not "enter job mode".
  -- Normal mode must not winrestview (stale lnum freezes the tail) or startinsert.
  local keep_follow_normal = term._keep_follow and ui and ui.mode == "n" and not force_insert
  local restore_normal = not force_insert and not keep_follow_normal and ui and ui.mode == "n"
  -- Snapshot before stopinsert: TermLeave may rewrite the live ui_state table.
  local view = ui and ui.view or nil

  local gen = begin_ui_apply(term)
  -- Block TermEnter from flipping ui.mode to "t" for the whole apply
  -- (common race: user autocmd BufEnter term://* startinsert during show).
  -- keep_follow_normal uses the same gen so that startinsert is stopinsert'd
  -- and the cursor is re-pinned, without winrestview of a stale snapshot.
  if restore_normal or keep_follow_normal then
    term._view_restore_gen = gen
  end
  -- ModeChanged uses this to avoid scheduling another stopinsert for the
  -- same gen. reassert_follow_cursor owns the follow-pin stopinsert.
  if keep_follow_normal then
    term._follow_pin_gen = gen
  end

  with_applying_ui_state(function()
    vim.api.nvim_set_current_win(term.win)
  end)
  vim.schedule(function()
    if term._ui_apply_gen ~= gen or not is_win_displayed(term.win) then
      finish_ui_apply(term, gen)
      return
    end

    local pending_view_restore = false
    local ok, err = pcall(function()
      with_applying_ui_state(function()
        vim.api.nvim_set_current_win(term.win)
        if keep_follow_normal then
          -- The window was hidden, so output could not tail. Pin once it is
          -- shown again. A BufEnter startinsert is left by stopinsert; the
          -- owner TermLeave pins, because a scheduled pin loses to
          -- terminal_check_cursor. Do not startinsert and do not winrestview.
          -- Once the cursor is on the last line outside job mode, the pin has
          -- stuck: finish this apply so a later TermEnter is not stopinsert'd.
          -- A scroll that cleared follow stays cleared.
          if term._keep_follow then
            reassert_follow_cursor(term, gen)
            if term._keep_follow and term.ui_state then
              term.ui_state.mode = "n"
            end
            -- Only while the tail is not pinned yet. A stuck pin finishes
            -- below (pending_view_restore stays false) so a later TermEnter
            -- stays in job mode. Scheduling again would re-arm stopinsert.
            if term._keep_follow and not follow_pin_stuck(term) then
              schedule_follow_pin(term, gen)
              pending_view_restore = true
            end
          end
          return
        end
        if restore_normal then
          -- Only leave job mode when needed (avoids a spurious TermLeave rewrite).
          local left_job = vim.api.nvim_get_mode().mode == "t" and in_terminal_win(term.win)
          if restore_view and view then
            if left_job then
              vim.cmd("stopinsert")
            end
            -- Always defer: set_buf / new splits jump to EOF before layout settles.
            schedule_normal_view_restore(term, view, gen)
            pending_view_restore = true
            return
          end
          if left_job then
            vim.cmd("stopinsert")
          end
          if term.ui_state then
            term.ui_state.mode = "n"
          end
          return
        end
        -- Jump to the end first — startinsert does nothing useful in scrollback.
        -- Skip when refocusing an already-visible window (restore_view == false).
        -- Clear follow here: this startinsert runs inside applying_ui_state, so
        -- TermEnter/ModeChanged will not clear the flag themselves.
        if restore_view then
          vim.api.nvim_win_call(term.win, function()
            local last = vim.api.nvim_buf_line_count(0)
            pcall(vim.api.nvim_win_set_cursor, 0, { last, 0 })
          end)
        end
        term._keep_follow = nil
        vim.cmd("startinsert")
      end)
    end)

    if not pending_view_restore then
      finish_ui_apply(term, gen)
    end
    if not ok then
      error(err)
    end
  end)
end

function M.save_ui_state(id, mode_override)
  save_ui_state(id, mode_override)
end

function M.apply_ui_state(id, opts)
  apply_ui_state(id, opts)
end

-- Tab-local: true only when the terminal window is shown in the current tabpage.
function M.is_visible(id)
  return is_visible(id)
end

-- Resolve a YAPT terminal id from a buffer (default: current buffer).
function M.id_for_buf(buf)
  return id_for_buf(buf)
end

-- Floats and non-focusable windows (which-key, notify, hover) are not
-- unfocus targets. nvim_set_current_win will enter focusable=false.
local function unfocus_window_usable(win)
  if not win or not vim.api.nvim_win_is_valid(win) or util.is_float_window(win) then
    return false
  end
  local cfg = vim.api.nvim_win_get_config(win)
  return cfg.focusable ~= false
end

-- Previous window in this tab, else the next usable window (wrapping).
-- Other terminals and quickfix count. No-op when this is the only window.
local function unfocus_destination(win)
  local altnr = vim.fn.winnr("#")
  if altnr > 0 then
    local alt = vim.fn.win_getid(altnr)
    if alt ~= 0 and alt ~= win and util.win_in_current_tab(alt) and unfocus_window_usable(alt) then
      return alt
    end
  end
  local wins = vim.api.nvim_tabpage_list_wins(0)
  local start
  for i, w in ipairs(wins) do
    if w == win then
      start = i
      break
    end
  end
  if not start then
    return nil
  end
  for offset = 1, #wins - 1 do
    local w = wins[(start + offset - 1) % #wins + 1]
    if unfocus_window_usable(w) then
      return w
    end
  end
  return nil
end

-- Move focus to another window in this tab without hiding the terminal.
-- From terminal-job mode, or normal mode with the cursor already on the last
-- line, park the cursor on the last line so the window keeps tailing output.
-- Remembered mode is "t" when this started in terminal-job mode, or when
-- re-parking a follow that already stored "t". A new follow from normal mode
-- stays "n". A cursor above the last line clears follow and stores "n".
-- An extra split whose window is not term.win only moves focus (and may pin
-- that split). It does not read or write the tracked window's follow, mode,
-- or view. No-op when this is the only window.
--
-- stopinsert from a terminal <Cmd> map only sets a flag. terminal_enter keeps
-- running and, on exit, terminal_check_cursor() puts the current window's
-- cursor back on the TUI row unless the window was already switched. Pin and
-- nvim_set_current_win stay in this call, before the mapping returns.
function M.unfocus(id)
  id = id or id_for_buf()
  local term = get_terminal(id)
  if not term or not term.buf or not vim.api.nvim_buf_is_valid(term.buf) then
    return
  end
  local win = vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= term.buf then
    return
  end
  local dest = unfocus_destination(win)
  if not dest or dest == win or not vim.api.nvim_win_is_valid(dest) then
    return
  end

  unfocusing = true
  local ok, err = pcall(function()
    -- Before stopinsert. Mode stays "t" until this mapping returns, so a
    -- later nvim_get_mode() cannot tell job mode from the exit transition.
    local job_mode = vim.api.nvim_get_mode().mode == "t"
    -- A still-valid term.win that is not this window is an extra split.
    -- Pin that split locally if it should keep tailing. Do not retarget
    -- term.win and do not read or write follow, mode, or view.
    local tracked = not term.win or not vim.api.nvim_win_is_valid(term.win) or term.win == win
    if not tracked then
      if job_mode then
        -- Same-buffer dest receives this leave. A different buffer does not
        -- write this terminal, and would never clear the skip.
        if vim.api.nvim_win_get_buf(dest) == term.buf then
          mark_unfocus_leave_skip(term)
        end
        vim.cmd("stopinsert")
      end
      if job_mode or cursor_on_last_line(win, term.buf) then
        pin_cursor_to_end(win, term.buf)
      end
    elseif job_mode or cursor_on_last_line(win, term.buf) then
      term.win = win
      -- Before stopinsert: ModeChanged/TermLeave must not record mode "n".
      -- The flag means "cursor stays on the last line", not "enter job mode".
      term._keep_follow = true
      if job_mode then
        vim.cmd("stopinsert")
      end
      pin_cursor_to_end(win, term.buf)
      local ui = ensure_ui_state(term)
      if cursor_on_last_line(win, term.buf) then
        -- job_mode was sampled before stopinsert. Re-parking keeps an
        -- existing "t"; a follow that starts from normal mode stays "n".
        if job_mode or ui.mode == "t" then
          ui.mode = "t"
        else
          ui.mode = "n"
        end
      else
        term._keep_follow = nil
        ui.mode = "n"
        local view = capture_view(win)
        if view then
          ui.view = view
        end
      end
    else
      -- Cursor is already above the last line. WinLeave skips while
      -- _keep_follow is set, so snapshot this window before switching.
      term.win = win
      term._keep_follow = nil
      local ui = ensure_ui_state(term)
      ui.mode = "n"
      local view = capture_view(win)
      if view then
        ui.view = view
      end
    end
    -- Same buffer and leaving job mode: terminal_check_cursor() yanks dest
    -- onto the TUI row before TermLeave. Stash the view for that autocmd.
    -- A normal-mode unfocus does not run TermLeave, so it must not stash.
    -- A vim.schedule restore runs after normal_check and looks like a scroll.
    if job_mode and vim.api.nvim_win_get_buf(dest) == term.buf then
      local dest_view = capture_view(dest)
      if dest_view then
        term._unfocus_dest_restore = { win = dest, view = dest_view }
      end
    end
    vim.api.nvim_set_current_win(dest)
    -- Leave events for this stopinsert run on dest, which must not clear the
    -- owner. They run when the mapping returns, before this scheduled clear.
    if job_mode then
      clear_terminal_job_buf(term.buf)
    end
  end)
  unfocusing = false
  if not ok then
    error(err)
  end
end

function M.is_running(id)
  if not is_buffer_valid(id) then
    return false
  end

  local term = get_terminal(id)
  if term and term.job_id then
    local job_info = vim.fn.jobwait({term.job_id}, 0)
    return job_info[1] == -1  -- -1 means still running
  end

  return false
end

function M.send_passthrough_key()
  if not get_job_id_for_current_buf() then
    util.notify("Not in a terminal buffer", vim.log.levels.WARN)
    return
  end
  local ok, key = pcall(vim.fn.getcharstr)
  if not ok or key == "" then return end
  do_send_key(key)
end

function M.send_forward_key(id)
  local seq = forward_seqs[id]
  if not seq then return end
  local job_id = get_job_id_for_current_buf()
  if not job_id then return end
  vim.api.nvim_chan_send(job_id, seq)
end

-- Verify the fullscreen window still actually shows the tracked terminal.
-- The user can move things out from under us (e.g. `:b otherfile`); when
-- that happens we treat fullscreen as no longer active.
local function fullscreen_window_still_valid()
  if not fullscreen_state.active then return false end
  if not fullscreen_state.saved_win
    or not vim.api.nvim_win_is_valid(fullscreen_state.saved_win) then
    return false
  end
  local term = get_terminal(fullscreen_state.terminal_id)
  if not term or not term.buf or not vim.api.nvim_buf_is_valid(term.buf) then
    return false
  end
  return vim.api.nvim_win_get_buf(fullscreen_state.saved_win) == term.buf
end

-- Reconcile fullscreen_state with reality. Call before reading or acting on it.
local function sync_fullscreen_state()
  if fullscreen_state.active and not fullscreen_window_still_valid() then
    local stale_term = get_terminal(fullscreen_state.terminal_id)
    if stale_term then stale_term.win = nil end
    reset_fullscreen_state()
  end
end

-- Forward-declared: hide() must route fullscreen ids through hide_fullscreen
-- so nvim_win_hide never drops a taken-over editor window without restore.
local hide_fullscreen

local function show_fullscreen(id)
  local term = get_terminal(id)
  if not term or not term.buf then return false end

  local current_win = vim.api.nvim_get_current_win()
  local current_buf = vim.api.nvim_win_get_buf(current_win)

  if vim.bo[current_buf].buftype ~= "terminal" then
    fullscreen_state.saved_buf = current_buf
  else
    fullscreen_state.saved_buf = util.find_or_create_restore_buffer(current_buf)
  end

  fullscreen_state.saved_win = current_win
  fullscreen_state.terminal_id = id
  fullscreen_state.active = true

  with_preserved_ui_intent(term, function()
    vim.api.nvim_win_set_buf(current_win, term.buf)
  end)
  term.win = current_win
  term.display_mode = "fullscreen"
  active_id = id
  return true
end

hide_fullscreen = function(mode_override)
  sync_fullscreen_state()
  if not fullscreen_state.active then return end

  local term_id = fullscreen_state.terminal_id

  with_hiding_terminal(function()
    save_ui_state(term_id, mode_override)

    if fullscreen_state.saved_win and vim.api.nvim_win_is_valid(fullscreen_state.saved_win) then
      local win = fullscreen_state.saved_win
      local replacement = fullscreen_state.saved_buf
      if not replacement or not vim.api.nvim_buf_is_valid(replacement) then
        replacement = util.find_or_create_restore_buffer()
      end
      vim.api.nvim_win_set_buf(win, replacement)
    end

    local term = get_terminal(term_id)
    if term then term.win = nil end

    reset_fullscreen_state()
  end)
end

-- Hide a terminal window in any tabpage. Unlike is_visible (tab-local), this
-- closes a still-valid win even when it lives in another tab (delete/switch).
-- Fullscreen terminals always go through hide_fullscreen (restore saved buffer).
local function hide(id, mode_override)
  id = id or active_id or default_id
  sync_fullscreen_state()
  local term = get_terminal(id)
  -- The normal-mode hide map passes "n". While follow is active that would
  -- replace a stored "t". Drop it here, including when this id is fullscreen
  -- and we delegate to hide_fullscreen. A direct save_ui_state(id, "n") is
  -- not this path.
  if term and term._keep_follow and mode_override == "n" then
    mode_override = nil
  end
  if fullscreen_state.active and fullscreen_state.terminal_id == id then
    hide_fullscreen(mode_override)
    return
  end

  if not term or not term.win or not vim.api.nvim_win_is_valid(term.win) then
    return
  end

  with_hiding_terminal(function()
    save_ui_state(id, mode_override)
    local win = term.win
    local ok = pcall(vim.api.nvim_win_hide, win)
    -- Only drop the handle when hide succeeded (or the win is already gone).
    -- A failed hide (e.g. last window) must keep term.win so show/switch
    -- do not open a duplicate for a still-displayed buffer.
    if ok or not vim.api.nvim_win_is_valid(win) then
      term.win = nil
    end
  end)
end

function M.hide(id, mode_override)
  hide(id, mode_override)
end

function M.is_fullscreen_active(id)
  sync_fullscreen_state()
  if id then
    return fullscreen_state.active and fullscreen_state.terminal_id == id
  end
  return fullscreen_state.active
end

-- True when a fullscreen terminal is shown in the *current* tabpage.
-- Use this in from-terminal handlers; is_fullscreen_active() is global.
-- When id is given, true only if that terminal is the one shown fullscreen here.
function M.is_fullscreen_in_current_tab(id)
  sync_fullscreen_state()
  if not (fullscreen_state.active and is_visible(fullscreen_state.terminal_id)) then
    return false
  end
  if id then
    return fullscreen_state.terminal_id == id
  end
  return true
end

function M.hide_fullscreen(mode_override)
  hide_fullscreen(mode_override)
end

-- Tear down fullscreen in its current tabpage, then take over the current window.
-- Used when the terminal is fullscreen in another tab and should rehome here
-- (parity with split reuse across tabs) instead of merely hiding.
local function rehome_fullscreen(id, apply_opts)
  hide_fullscreen()
  show_fullscreen(id)
  apply_ui_state(id, apply_opts)
end

local function split_size(config)
  if config.split.position == "right" or config.split.position == "left" then
    return math.floor(vim.o.columns * config.split.size)
  end
  return math.floor(vim.o.lines * config.split.size)
end

local function apply_split_size(win, config)
  local size = split_size(config)
  if config.split.position == "right" or config.split.position == "left" then
    vim.api.nvim_win_set_width(win, size)
  else
    vim.api.nvim_win_set_height(win, size)
  end
end

local function split_direction(config)
  if config.split.position == "right" then
    return "right"
  elseif config.split.position == "left" then
    return "left"
  elseif config.split.position == "top" then
    return "above"
  end
  return "below"
end

local function open_split_window(term, config)
  local split_cmd
  if config.split.position == "right" then
    split_cmd = "rightbelow vsplit"
  elseif config.split.position == "left" then
    split_cmd = "leftabove vsplit"
  elseif config.split.position == "top" then
    split_cmd = "leftabove split"
  else  -- bottom
    split_cmd = "rightbelow split"
  end

  vim.cmd(split_cmd)
  term.win = vim.api.nvim_get_current_win()
  with_preserved_ui_intent(term, function()
    vim.api.nvim_win_set_buf(term.win, term.buf)
  end)
  apply_split_size(term.win, config)
end

-- Reuse a still-valid terminal window.
-- nvim_win_hide closes the window, so this cannot revive a hidden split; it
-- only focuses a window already in this tabpage, or moves one from another
-- tabpage into the configured split position/size.
-- Stealing the window across tabs is intentional: with tab-local is_visible,
-- show/toggle from another tabpage rehomes the existing window here rather
-- than leaving a stray split behind or opening a second one.
local function reuse_split_window(term, config)
  if not term.win or not vim.api.nvim_win_is_valid(term.win) then
    return false
  end
  -- Fullscreen windows must be torn down via hide_fullscreen (restore buffer),
  -- not relocated with nvim_win_set_config.
  if fullscreen_state.active and term.win == fullscreen_state.saved_win then
    return false
  end
  if is_win_displayed(term.win) then
    with_preserved_ui_intent(term, function()
      vim.api.nvim_set_current_win(term.win)
    end)
    return true
  end

  local old_win = term.win
  local ok = pcall(vim.api.nvim_win_set_config, old_win, {
    split = split_direction(config),
    win = vim.api.nvim_get_current_win(),
  })
  if ok and is_win_displayed(term.win) then
    with_preserved_ui_intent(term, function()
      if vim.api.nvim_win_get_buf(term.win) ~= term.buf then
        vim.api.nvim_win_set_buf(term.win, term.buf)
      end
      vim.api.nvim_set_current_win(term.win)
    end)
    apply_split_size(term.win, config)
    return true
  end

  -- Move failed: close the stray window so open_split_window won't duplicate it.
  if vim.api.nvim_win_is_valid(old_win) then
    pcall(vim.api.nvim_win_close, old_win, true)
  end
  term.win = nil
  return false
end

local function show(id, config)
  id = id or active_id or default_id
  if not is_buffer_valid(id) then
    return false
  end

  local term = get_terminal(id)
  if not term then
    return false
  end

  -- Demote/rehome: never move a fullscreen surface into a split in place.
  sync_fullscreen_state()
  if fullscreen_state.active and fullscreen_state.terminal_id == id then
    hide_fullscreen()
  end

  if not reuse_split_window(term, config) then
    open_split_window(term, config)
  end

  term.display_mode = "split"
  active_id = id

  return true
end

-- Show without toggling (for switch_to and other "make visible" callers).
function M.show(id, config)
  return show(id, config)
end

function M.show_fullscreen(id)
  return show_fullscreen(id)
end

-- Strip trailing spaces from yanked lines and write back to the register.
-- Targets terminal cell-grid padding (spaces), not generic whitespace / hard-wrap.
-- Also syncs clipboard registers when 'clipboard' mirrors the unnamed register.
local function apply_trimmed_yank_register()
  if vim.v.event.operator ~= "y" then
    return
  end
  local lines = vim.v.event.regcontents
  if type(lines) ~= "table" then
    return
  end
  local trimmed = {}
  local changed = false
  local max_width = 0
  for i, line in ipairs(lines) do
    local t = line:gsub(" +$", "")
    trimmed[i] = t
    if t ~= line then
      changed = true
    end
    local w = vim.fn.strdisplaywidth(t)
    if w > max_width then
      max_width = w
    end
  end
  if not changed then
    return
  end
  local original_reg = vim.v.event.regname
  local reg = original_reg
  if reg == "" then
    reg = '"'
  else
    -- Uppercase means append-mode yank; setreg with uppercase appends again.
    reg = reg:lower()
  end
  local regtype = vim.v.event.regtype
  -- Blockwise paste re-pads to the stored width; update it after trim.
  if type(regtype) == "string" and regtype:sub(1, 1) == "\022" then
    regtype = "\022" .. max_width
  end

  vim.fn.setreg(reg, trimmed, regtype)
  -- Named/clipboard yanks also update unnamed; set it explicitly after trim.
  if reg ~= '"' then
    vim.fn.setreg('"', trimmed, regtype)
  end

  -- Mirror clipboard only for unnamed yanks (Neovim already set +/* for "+y/*y).
  if original_reg == "" or original_reg == '"' then
    local clipboard = vim.o.clipboard
    local has_unnamedplus = clipboard:find("unnamedplus", 1, true) ~= nil
    local has_unnamed = clipboard:gsub("unnamedplus", ""):find("unnamed", 1, true) ~= nil
    if has_unnamedplus then
      vim.fn.setreg("+", trimmed, regtype)
    end
    if has_unnamed then
      vim.fn.setreg("*", trimmed, regtype)
    end
  end
end

-- Create a new terminal instance (reusable function for creating terminals).
-- @param id string Terminal ID
-- @param config table Plugin config
-- @param command string|nil Command to run (resolved via config_module if nil)
-- @param display_mode string|nil "split" (default) or "fullscreen"
local function create_terminal_instance(id, config, command, display_mode)
  display_mode = display_mode or "split"
  command = config_module.resolve_command(command, config)

  if not terminals[id] then
    terminals[id] = {
      buf = nil,
      win = nil,
      job_id = nil,
      id = id,
      display_mode = display_mode,
    }
  end

  local term = terminals[id]
  term.display_mode = display_mode
  ensure_ui_state(term)
  term.buf = vim.api.nvim_create_buf(false, true)

  if display_mode == "fullscreen" then
    show_fullscreen(id)
  else
    show(id, config)
  end

  term.job_id = vim.fn.termopen(command, {
    on_exit = function(_, exit_code, _)
      -- Capture fullscreen state before clearing it; we may need to restore
      -- the user's window after the buffer is gone.
      local was_fullscreen = fullscreen_state.active and fullscreen_state.terminal_id == id
      local fs_saved_win = fullscreen_state.saved_win
      local fs_saved_buf = fullscreen_state.saved_buf

      if was_fullscreen then
        reset_fullscreen_state()
      end

      term.job_id = nil
      if term.buf and vim.api.nvim_buf_is_valid(term.buf) then
        vim.api.nvim_buf_delete(term.buf, { force = true })
      end
      term.buf = nil
      term.win = nil

      if term.forward_ids then
        for _, fwd_id in ipairs(term.forward_ids) do
          forward_seqs[fwd_id] = nil
        end
        term.forward_ids = nil
      end

      terminals[id] = nil

      if active_id == id then
        active_id = nil
      end

      for _, callback in ipairs(cleanup_callbacks) do
        pcall(callback, id, exit_code)
      end

      if config.term_opts.on_close then
        config.term_opts.on_close(exit_code)
      end

      if was_fullscreen then
        vim.schedule(function()
          if fs_saved_win and vim.api.nvim_win_is_valid(fs_saved_win) then
            local replacement = fs_saved_buf
            if not replacement or not vim.api.nvim_buf_is_valid(replacement) then
              replacement = util.find_or_create_restore_buffer()
            end
            vim.api.nvim_win_set_buf(fs_saved_win, replacement)
          end
        end)
      end
    end,
  })

  local term_keys = vim.tbl_deep_extend("force", {}, config_module.defaults.terminal_keybindings, config.terminal_keybindings or {})
  if config.terminal_keybindings and config.terminal_keybindings.forward_keys then
    term_keys.forward_keys = config.terminal_keybindings.forward_keys
  end

  -- Backward compatibility: if someone only set `exit`, treat it as `hide`.
  if (term_keys.hide == nil or term_keys.hide == "") and term_keys.exit and term_keys.exit ~= "" then
    term_keys.hide = term_keys.exit
  end
  -- Always use one key for both actions.
  term_keys.exit = term_keys.hide

  if term_keys.exit and term_keys.exit ~= "" then
    -- Use <Cmd> without <C-\><C-n> so we can record terminal-job mode before hide.
    vim.api.nvim_buf_set_keymap(term.buf, 't', term_keys.exit, '<Cmd>lua require("yapt").hide_from_terminal_handler("t")<CR>', {
      noremap = true,
      silent = true,
      desc = "Hide terminal window"
    })
  end

  if term_keys.hide and term_keys.hide ~= "" then
    vim.api.nvim_buf_set_keymap(term.buf, 'n', term_keys.hide, '<Cmd>lua require("yapt").hide_from_terminal_handler("n")<CR>', {
      noremap = true,
      silent = true,
      desc = "Hide terminal window"
    })
  end

  if term_keys.unfocus and term_keys.unfocus ~= "" then
    local unfocus_rhs = '<Cmd>lua require("yapt").unfocus_terminal_handler()<CR>'
    local unfocus_opts = {
      noremap = true,
      silent = true,
      desc = "Move focus to another window"
    }
    vim.api.nvim_buf_set_keymap(term.buf, 't', term_keys.unfocus, unfocus_rhs, unfocus_opts)
    vim.api.nvim_buf_set_keymap(term.buf, 'n', term_keys.unfocus, unfocus_rhs, unfocus_opts)
  end

  local term_cfg = config.terminal or {}
  if term_cfg.trim_yank_trailing_whitespace ~= false then
    vim.api.nvim_create_autocmd("TextYankPost", {
      buffer = term.buf,
      callback = apply_trimmed_yank_register,
    })
  end

  vim.api.nvim_create_autocmd("TermEnter", {
    buffer = term.buf,
    callback = function()
      -- This buffer entered job mode even when the ui update below is skipped.
      remember_terminal_job(term.buf)
      local t = terminals[id]
      if hiding_terminal or applying_ui_state then
        return
      end
      if not t or suppress_winenter_restore(t) then
        return
      end
      -- Do not clobber a pending normal-mode or follow restore (show→apply
      -- race with user BufEnter startinsert autocmds). The startinsert
      -- branch clears _keep_follow itself while these guards are set.
      if t._view_restore_gen then
        return
      end
      t._keep_follow = nil
      ensure_ui_state(t).mode = "t"
    end,
  })

  -- ModeChanged tracks t↔n more reliably than TermLeave alone, and rejects
  -- deferred BufEnter startinsert while a normal-mode view restore is pending.
  vim.api.nvim_create_autocmd("ModeChanged", {
    buffer = term.buf,
    callback = function()
      local t = terminals[id]
      if not t then
        return
      end
      -- Extra-split unfocus of this buffer. Not a leave of the tracked window.
      if take_unfocus_leave_skip(t) then
        return
      end
      local mode = vim.api.nvim_get_mode().mode
      -- new_mode, not mode(): a t→nt leave must not record this buffer as the job.
      if vim.v.event.new_mode == "t" then
        remember_terminal_job(t.buf)
      end
      -- t→nt after a window switch is delivered here, not to the job buffer.
      -- Leave that terminal's ui state alone. Do not clear terminal_job_buf:
      -- TermLeave in this same turn still has to ignore the destination.
      local owned_leave = vim.v.event.old_mode == "t" and terminal_job_owned_by(t.buf)
      if vim.v.event.old_mode == "t" and not owned_leave then
        return
      end
      if hiding_terminal then
        return
      end
      if t._view_restore_gen then
        -- Follow-pin stopinsert is only in reassert_follow_cursor. View restore
        -- still leaves job mode, and only when this window is current.
        if mode == "t" and t._follow_pin_gen ~= t._view_restore_gen then
          local win = t.win
          vim.schedule(function()
            local cur = terminals[id]
            if not cur or not cur._view_restore_gen then
              return
            end
            if cur._follow_pin_gen == cur._view_restore_gen then
              return
            end
            if in_terminal_win(win) and vim.api.nvim_get_mode().mode == "t" then
              vim.cmd("stopinsert")
            end
          end)
        end
        return
      end
      if applying_ui_state or suppress_winenter_restore(t) then
        return
      end
      -- Real job entry ends follow. "nt" is normal mode for as long as this
      -- terminal buffer is current (:help mode()) and must keep the flag.
      if mode == "t" then
        t._keep_follow = nil
      end
      if t._keep_follow and mode ~= "t" then
        -- Unfocus parks the cursor on the last line. Recording mode "n" here
        -- would restore that pre-leave view and freeze autoscroll.
        return
      end
      if mode == "t" then
        ensure_ui_state(t).mode = "t"
      elseif mode ~= "c" and not mode:match("^[itR]") then
        ensure_ui_state(t).mode = "n"
        local view = capture_view(t.win)
        if view then
          t.ui_state.view = view
        end
        if owned_leave then
          clear_terminal_job_buf(t.buf)
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd("TermLeave", {
    buffer = term.buf,
    callback = function()
      local buf = term.buf
      -- After terminal_check_cursor(), before normal_check. Also when the
      -- extra-split skip below would return first. Clears the stash.
      restore_unfocus_dest(terminals[id])
      -- Extra-split unfocus of this buffer. Not a leave of the tracked window.
      -- Before the owner check, so this callback still clears the skip.
      if take_unfocus_leave_skip(terminals[id]) then
        return
      end
      -- Same misdirected t→nt as ModeChanged. Ignore without clearing the
      -- job buffer so the other event still recognizes the real owner.
      if not terminal_job_owned_by(buf) then
        return
      end
      -- terminal_check_cursor() already moved this window onto the TUI row.
      -- Pin here, synchronously. A vim.schedule pin does not stick. A
      -- misdirected TermLeave is not the owner and returned above, so unfocus
      -- cannot pin the destination. A scroll that cleared follow is not pinned
      -- and the flag is not set again.
      local t_pin = terminals[id]
      if t_pin and t_pin._follow_pinning and not hiding_terminal then
        -- Only this pin's generation. A cleared _follow_pin_gen must not
        -- finish whatever apply is current.
        local pin_gen = t_pin._follow_pin_gen
        if pin_gen and pin_gen == t_pin._ui_apply_gen then
          if t_pin._keep_follow and is_win_displayed(t_pin.win) then
            pin_cursor_to_end(t_pin.win, t_pin.buf)
          end
          t_pin._follow_pinning = nil
          complete_follow_pin(t_pin, pin_gen)
        else
          t_pin._follow_pinning = nil
        end
      elseif t_pin and t_pin._follow_pinning and hiding_terminal then
        t_pin._follow_pinning = nil
      end
      if hiding_terminal then
        return
      end
      -- Defer: distinguish intentional stopinsert / <C-\><C-n> (still on this
      -- buffer) from focus leaving the window (keep prior mode, usually "t").
      local job_gen = terminal_job_gen
      vim.schedule(function()
        if hiding_terminal or applying_ui_state or not terminals[id] then
          return
        end
        local t = terminals[id]
        local still_owner = terminal_job_buf == buf and terminal_job_gen == job_gen
        -- Nested post-stopinsert view restore still pending, or follow owns
        -- the cursor: do not clobber ui.view. The owner clear below still runs.
        if not t._view_restore_gen and not t._keep_follow
          and vim.api.nvim_buf_is_valid(buf)
          and vim.api.nvim_get_current_buf() == buf then
          save_ui_state(id, "n")
        end
        -- Clear even when focus already left. The owner buffer's TermLeave is
        -- the one that scheduled this; a newer TermEnter bumps job_gen.
        if still_owner then
          terminal_job_buf = nil
        end
      end)
    end,
  })

  -- Keep ui.view fresh while scrolling in normal mode.
  vim.api.nvim_create_autocmd({ "CursorMoved", "WinScrolled" }, {
    buffer = term.buf,
    callback = function()
      if hiding_terminal or applying_ui_state then
        return
      end
      local t = terminals[id]
      if not t or not t.ui_state then
        return
      end
      -- This window's job-mode cursor is the TUI row, often not the last
      -- line. Ignore "t" only then. Another terminal's job mode must not
      -- hide a scroll here. "nt" can still end follow. An invalid t.win is
      -- not this window, so it must not take this return.
      local mode = vim.api.nvim_get_mode().mode
      if mode == "t"
        and t.win
        and vim.api.nvim_win_is_valid(t.win)
        and vim.api.nvim_get_current_win() == t.win then
        return
      end
      -- Same-buffer job-mode unfocus: term.win stays on the TUI row until
      -- TermLeave winrestview clears the stash. Ignore it the same way as
      -- _follow_pinning, including the view snapshot below.
      if unfocus_dest_restore_pending(t, t.win) then
        return
      end
      if t._keep_follow then
        -- Output tailing keeps this cursor on the last line, focused or not.
        -- A scroll moves it off that line and ends follow. _follow_pinning
        -- covers only this terminal's stopinsert-to-TermLeave gap, so
        -- terminal_check_cursor's TUI row is not a scroll. Another terminal's
        -- restore must not hide a scroll here. A missing window must not:
        -- cursor_on_last_line is false for an invalid win.
        if unfocusing
          or t._follow_pinning
          or not t.win
          or not vim.api.nvim_win_is_valid(t.win)
          or cursor_on_last_line(t.win, t.buf) then
          return
        end
        -- Not this window's job (mode ~= "t", or "t" in another terminal).
        -- Snapshot before a follow-pin retry can pull the cursor back.
        t._keep_follow = nil
        t._follow_pinning = nil
        t.ui_state.mode = "n"
        local view = capture_view(t.win)
        if view then
          t.ui_state.view = view
        end
        if t._follow_pin_gen and t._follow_pin_gen == t._ui_apply_gen then
          finish_ui_apply(t, t._follow_pin_gen)
        end
        return
      end
      if t._view_restore_gen or suppress_winenter_restore(t) then
        return
      end
      if t.ui_state.mode ~= "n" then
        return
      end
      local view = capture_view(t.win)
      if view then
        t.ui_state.view = view
      end
    end,
  })

  -- Snapshot scroll when leaving a terminal already in normal mode (<C-w>,
  -- click, etc.). Do not force mode to "n": TermLeave owns t→n only while
  -- focus remains on the buffer; leaving job mode must keep ui_state "t".
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = term.buf,
    callback = function()
      if hiding_terminal then
        return
      end
      local t = terminals[id]
      if not t or t._keep_follow or not t.ui_state or t.ui_state.mode ~= "n" then
        return
      end
      local view = capture_view(t.win)
      if view then
        t.ui_state.view = view
      end
    end,
  })

  -- Restore snapshotted scroll when returning to a terminal left in normal
  -- mode. Deferred so terminal set_buf / focus can settle; skipped while
  -- apply_ui_state owns restore (picker/rename/same-term restore_view=false).
  vim.api.nvim_create_autocmd("WinEnter", {
    buffer = term.buf,
    callback = function()
      -- terminal_check_focus() keeps job mode across a window change that
      -- does not stopinsert, without a new TermEnter. The window we landed
      -- on is in job mode, including during hide(). Own it and end follow.
      -- unfocus() is still inside its switch; the destination must not steal
      -- the record. apply_ui_state is about to re-pin a normal-mode follow.
      if not unfocusing and not applying_ui_state and vim.api.nvim_get_mode().mode == "t" then
        remember_terminal_job(term.buf)
        local entered = terminals[id]
        if entered then
          entered._keep_follow = nil
          ensure_ui_state(entered).mode = "t"
        end
      end
      if hiding_terminal or applying_ui_state then
        return
      end
      local t = terminals[id]
      -- Follow keeps the live end. Restoring ui.view would jump to a stale line.
      if not t or t._keep_follow or not t.ui_state or t.ui_state.mode ~= "n" then
        return
      end
      if suppress_winenter_restore(t) then
        return
      end
      if not is_win_displayed(t.win) or t.win ~= vim.api.nvim_get_current_win() then
        return
      end
      local win = t.win
      local view = t.ui_state.view
      vim.schedule(function()
        local cur = terminals[id]
        if hiding_terminal or applying_ui_state or not cur then
          return
        end
        if suppress_winenter_restore(cur) then
          return
        end
        if not cur.ui_state or cur.ui_state.mode ~= "n" then
          return
        end
        if cur.win ~= win or not is_win_displayed(cur.win) then
          return
        end
        if vim.api.nvim_get_current_win() ~= cur.win then
          return
        end
        local applied = restore_normal_view(cur, view or cur.ui_state.view, nil)
        if applied and cur.ui_state then
          cur.ui_state.view = applied
        end
      end)
    end,
  })

  -- Terminal-job maps use <Cmd> and pass "t" so hide/switch paths keep job mode
  -- in ui_state (avoid <C-\><C-n>, which would TermLeave and record "n").
  if term_keys.new and term_keys.new ~= "" then
    vim.api.nvim_buf_set_keymap(term.buf, 't', term_keys.new, '<Cmd>lua require("yapt").new_terminal_from_terminal_handler("t")<CR>', {
      noremap = true,
      silent = true,
      desc = "Create new terminal (hide current first)"
    })
  end

  if term_keys.rename and term_keys.rename ~= "" then
    vim.api.nvim_buf_set_keymap(term.buf, 't', term_keys.rename, '<Cmd>lua require("yapt").rename_terminal_handler("t")<CR>', {
      noremap = true,
      silent = true,
      desc = "Rename current terminal"
    })
  end

  if term_keys.select and term_keys.select ~= "" then
    vim.api.nvim_buf_set_keymap(term.buf, 't', term_keys.select, '<Cmd>lua require("yapt").select_terminal_from_terminal_handler("t")<CR>', {
      noremap = true,
      silent = true,
      desc = "Select terminal"
    })
  end

  if term_keys.prompt_last and term_keys.prompt_last ~= "" then
    vim.api.nvim_buf_set_keymap(term.buf, 't', term_keys.prompt_last, '<Cmd>lua require("yapt").open_last_prompt_from_terminal_handler("t")<CR>', {
      noremap = true,
      silent = true,
      desc = "Open last prompt file"
    })
  end

  if term_keys.toggle_fullscreen and term_keys.toggle_fullscreen ~= "" then
    vim.api.nvim_buf_set_keymap(term.buf, 't', term_keys.toggle_fullscreen, '<Cmd>lua require("yapt").fullscreen_toggle_from_terminal_handler("t")<CR>', {
      noremap = true,
      silent = true,
      desc = "Toggle fullscreen mode"
    })
    vim.api.nvim_buf_set_keymap(term.buf, 'n', term_keys.toggle_fullscreen, '<Cmd>lua require("yapt").fullscreen_toggle_from_terminal_handler("n")<CR>', {
      noremap = true,
      silent = true,
      desc = "Toggle fullscreen mode"
    })
  end

  if term_keys.passthrough and term_keys.passthrough ~= "" then
    local passthrough_rhs = '<Cmd>lua require("yapt.terminal").send_passthrough_key()<CR>'
    vim.api.nvim_buf_set_keymap(term.buf, 'n', term_keys.passthrough, passthrough_rhs, {
      noremap = true,
      silent = true,
      desc = "Send next key to TUI application"
    })
  end

  if term_keys.forward_keys then
    term.forward_ids = {}
    for _, key in ipairs(term_keys.forward_keys) do
      forward_seq_counter = forward_seq_counter + 1
      local fwd_id = forward_seq_counter
      term.forward_ids[#term.forward_ids + 1] = fwd_id
      local nvim_key = vim.api.nvim_replace_termcodes(key, true, false, true)
      forward_seqs[fwd_id] = neovim_key_to_termseq(nvim_key)
      local rhs = string.format(
        '<Cmd>lua require("yapt.terminal").send_forward_key(%d)<CR>', fwd_id)
      vim.api.nvim_buf_set_keymap(term.buf, 'n', key, rhs, {
        noremap = true,
        silent = true,
        desc = "Forward " .. key .. " to TUI"
      })
      local neovide_key = key:gsub("^<C%-M%-(%l)>$", function(c)
        return "<M-C-" .. c:upper() .. ">"
      end)
      if neovide_key ~= key then
        vim.api.nvim_buf_set_keymap(term.buf, 'n', neovide_key, rhs, {
          noremap = true,
          silent = true,
          desc = "Forward " .. neovide_key .. " to TUI"
        })
      end
    end
  end

  -- show() ran before these autocmds existed. terminal_check_focus() can
  -- already be in job mode on this buffer, so TermEnter/WinEnter never saw
  -- the switch and a later startinsert will not fire TermEnter either.
  if vim.api.nvim_get_current_buf() == term.buf and vim.api.nvim_get_mode().mode == "t" then
    remember_terminal_job(term.buf)
  end

  vim.schedule(function() vim.cmd("startinsert") end)

  active_id = id

  if config.term_opts.on_open then
    config.term_opts.on_open()
  end

  return term
end

-- Toggle terminal visibility.
--
-- Semantics (tab-local visibility):
--   - Visible in this tabpage (split or fullscreen) -> hide it.
--   - Fullscreen / split only in another tabpage -> rehome here (do not hide).
--   - Otherwise -> show it in split mode (creating it if needed).
--
-- Pressing the split-toggle key while the terminal is fullscreen in this
-- tabpage no longer silently demotes it to a split: it just hides.
function M.toggle(config, id, command)
  id = id or active_id or default_id
  sync_fullscreen_state()

  if fullscreen_state.active and fullscreen_state.terminal_id == id then
    if is_visible(id) then
      hide_fullscreen()
    else
      rehome_fullscreen(id)
    end
    return
  end

  if is_visible(id) then
    hide(id)
  elseif is_buffer_valid(id) and M.is_running(id) then
    show(id, config)
    apply_ui_state(id)
  else
    create_terminal_instance(id, config, command, "split")
  end
end

-- Toggle a terminal in fullscreen mode.
--
-- Semantics (tab-local visibility):
--   - Fullscreen in this tabpage -> hide it (restore the previous buffer).
--   - Fullscreen only in another tabpage -> rehome into the current window.
--   - Shown in a split here -> hide the split, then take over the focused window.
--   - Otherwise -> show it (creating if needed) in fullscreen mode.
--
-- apply_opts: forwarded to apply_ui_state / rehome when showing (e.g. force_insert).
function M.toggle_fullscreen(config, id, command, apply_opts)
  id = id or active_id or default_id
  sync_fullscreen_state()

  if fullscreen_state.active and fullscreen_state.terminal_id == id then
    if is_visible(id) then
      local mode_override = nil
      local term = get_terminal(id)
      if term and term.buf and vim.api.nvim_get_current_buf() == term.buf then
        local m = vim.api.nvim_get_mode().mode
        mode_override = (m == "t") and "t" or "n"
      end
      hide_fullscreen(mode_override)
    else
      rehome_fullscreen(id, apply_opts)
    end
    return
  end

  -- A different terminal is currently fullscreen; release that first
  -- so we don't end up with two fullscreen entries fighting for state.
  if fullscreen_state.active then
    hide_fullscreen()
  end

  -- Drop any existing window for this terminal (split in this tab or another).
  -- Use hide() rather than is_visible(): visibility is tab-local, but a split
  -- in another tabpage must still be closed to avoid duplicate windows.
  -- After nvim_win_hide focus shifts to a remaining window, which is the
  -- one we want to take over for fullscreen -- no need for vim.schedule.
  hide(id)

  if is_buffer_valid(id) and M.is_running(id) then
    show_fullscreen(id)
    apply_ui_state(id, apply_opts)
  else
    create_terminal_instance(id, config, command, "fullscreen")
  end
end

-- Show the terminal in its preferred (last used) display mode.
-- Used by callers that want to *make the terminal visible* without toggling
-- (e.g. send_prompt_file_to_terminal), so the terminal doesn't get demoted from
-- fullscreen to split unexpectedly. No-op if already visible in this tabpage
-- (callers that need insert when already visible must apply_ui_state themselves);
-- rehomes when the preferred view exists only in another tabpage.
-- When it actually shows or rehomes, force-inserts for send/paste workflows.
function M.show_in_preferred_mode(config, id, command)
  id = id or active_id or default_id
  sync_fullscreen_state()

  if fullscreen_state.active and fullscreen_state.terminal_id == id then
    if is_visible(id) then
      return
    end
    rehome_fullscreen(id, { force_insert = true })
    return
  end
  if is_visible(id) then
    return
  end

  local term = get_terminal(id)
  local mode = (term and term.display_mode) or "split"

  if mode == "fullscreen" then
    if is_buffer_valid(id) and M.is_running(id) then
      show_fullscreen(id)
      apply_ui_state(id, { force_insert = true })
    else
      create_terminal_instance(id, config, command, "fullscreen")
    end
  else
    if is_buffer_valid(id) and M.is_running(id) then
      show(id, config)
      apply_ui_state(id, { force_insert = true })
    else
      create_terminal_instance(id, config, command, "split")
    end
  end
end

-- Send text to the terminal
function M.send_text(text, id)
  id = id or active_id or default_id

  if not M.is_running(id) then
    util.notify("Terminal is not running", vim.log.levels.WARN)
    return false
  end

  local term = get_terminal(id)
  if term and term.job_id then
    if not text:match("\n$") then
      text = text .. "\n"
    end
    vim.api.nvim_chan_send(term.job_id, text)

    if is_win_displayed(term.win) then
      ensure_ui_state(term).mode = "t"
      apply_ui_state(id, { force_insert = true })
    end

    return true
  end

  return false
end

-- Get terminal state (for debugging / coordination with other modules)
function M.get_state(id)
  id = id or active_id or default_id
  local term = get_terminal(id)

  if not term then
    return {
      id = id,
      exists = false,
      is_visible = false,
      is_running = false,
      display_mode = nil,
    }
  end

  return {
    id = id,
    buf = term.buf,
    win = term.win,
    job_id = term.job_id,
    display_mode = term.display_mode,
    is_visible = is_visible(id),
    is_running = M.is_running(id),
  }
end

-- Get the last preferred display mode for a terminal.
-- Returns "split" by default if the terminal is unknown.
function M.get_display_mode(id)
  local term = get_terminal(id)
  return (term and term.display_mode) or "split"
end

-- Register a cleanup callback (called when terminal exits)
-- @param callback function(id, exit_code)
function M.register_cleanup_callback(callback)
  table.insert(cleanup_callbacks, callback)
end

-- Expose internal functions for tabs module
M._create_terminal_instance = create_terminal_instance
M._get_terminal = get_terminal
M._set_active = function(id) active_id = id end
M._get_active_id = function() return active_id end

return M
