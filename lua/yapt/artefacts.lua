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

-- U+00A0, U+1680, U+2000–U+200A, U+2028, U+2029, U+202F, U+205F, U+3000.
-- Lua character classes are bytes, so each codepoint is substituted on its own.
-- The set answers "is this whole character one of them" in O(1).
local unicode_spaces = {}
local unicode_space_set = {}
local function add_unicode_space(cp)
  local ch = vim.fn.nr2char(cp)
  unicode_spaces[#unicode_spaces + 1] = ch
  unicode_space_set[ch] = true
end
add_unicode_space(0x00A0)
add_unicode_space(0x1680)
for cp = 0x2000, 0x200A do
  add_unicode_space(cp)
end
add_unicode_space(0x2028)
add_unicode_space(0x2029)
add_unicode_space(0x202F)
add_unicode_space(0x205F)
add_unicode_space(0x3000)

-- One whole character is whitespace when Lua's %s matches it (ASCII bytes never
-- match for a multibyte character) or it is one of the unicode spaces above.
local function is_space_char(ch)
  return ch ~= "" and (unicode_space_set[ch] or ch:match("^%s$") ~= nil)
end

-- Format characters that change how a path is displayed (bidi marks, zero-width
-- joiners, BOM). Replaced with "-" so two titles cannot glue together.
local unicode_format = {}
local function add_unicode_format(cp)
  unicode_format[#unicode_format + 1] = vim.fn.nr2char(cp)
end
for cp = 0x200B, 0x200F do
  add_unicode_format(cp)
end
for cp = 0x202A, 0x202E do
  add_unicode_format(cp)
end
for cp = 0x2066, 0x2069 do
  add_unicode_format(cp)
end
add_unicode_format(0xFEFF)

local function replace_unicode_spaces(name)
  for _, ch in ipairs(unicode_spaces) do
    name = name:gsub(ch, " ")
  end
  return name
end

local function replace_unicode_format(name)
  for _, ch in ipairs(unicode_format) do
    name = name:gsub(ch, "-")
  end
  return name
end

-- A path segment that is exactly "." or "..". ".nvim-yapt" is a normal name.
local function has_dot_segment(path)
  for seg in path:gmatch("[^/]+") do
    if seg == "." or seg == ".." then
      return true
    end
  end
  return false
end

local function strip_trailing_slash(path)
  if path ~= "/" then
    path = path:gsub("/+$", "")
  end
  return path
end

-- "$VAR" / "${VAR}" in one left-to-right pass. Each value is inserted
-- literally. A value with a glob or a "." / ".." segment is refused.
-- An absolute value ("/" or "~...") must be the whole directory: if any
-- path text already precedes it, cache/$DIR would collapse under the cwd.
-- @return string|nil expanded, string|nil warning
local function expand_vars(s)
  local parts = {}
  local i = 1
  while i <= #s do
    local rest = s:sub(i)
    local braced = rest:match("^%${([%w_]+)}")
    local bare = (not braced) and rest:match("^%$([%w_]+)") or nil
    local var = braced or bare
    if var then
      local val = vim.uv.os_getenv(var)
      if type(val) ~= "string" or val == "" then
        return nil, "Artefact directory variable is unset or empty: $" .. var
      end
      if val:find("[%*%?%[]") then
        return nil, "Artefact directory variable value contains a glob character: $" .. var
      end
      if has_dot_segment(val) then
        return nil, "Artefact directory variable value contains a '.' or '..' path segment: $" .. var
      end
      local first = val:sub(1, 1)
      if (first == "/" or first == "~") and table.concat(parts) ~= "" then
        return nil, "Artefact directory variable is absolute and is not the whole directory: $" .. var
      end
      parts[#parts + 1] = val
      i = i + (braced and (3 + #var) or (1 + #var))
    else
      parts[#parts + 1] = s:sub(i, i)
      i = i + 1
    end
  end
  return table.concat(parts)
end

-- Leading "~", "~/...", or "~user" only. The home directory is a literal
-- prefix: "$" inside it is not expanded and does not reject the setting.
-- "$VAR" / "${VAR}" are expanded only in the original remainder.
-- "~-" / "~+" (and "~-/...", "~+/...", "~-user", "~+user") are rejected:
-- vim.fn.expand("~-") is $OLDPWD and expand("~+") is the cwd.
-- @return string|nil expanded, string|nil warning
local function expand_leading_tilde(dir)
  if type(dir) ~= "string" or dir:sub(1, 1) ~= "~" then
    return dir
  end

  -- A username must not be "-" or "+" and must not start with either.
  -- That is exactly a second character of "-" or "+".
  local second = dir:sub(2, 2)
  if second == "-" or second == "+" then
    local token = dir:match("^~[^/]*") or dir
    return nil, "Artefact directory " .. token .. " could not be expanded"
  end

  local home, rest
  if dir == "~" or second == "/" then
    home = vim.uv.os_homedir()
    rest = dir:sub(2)
  else
    local user, tail = dir:match("^~([^/]+)(.*)$")
    if not user or user == "" or not user:match("^[%w._-]+$") then
      return nil, "Artefact directory ~ could not be expanded"
    end
    local token = "~" .. user
    -- Only the ~user token, so expand cannot see "$", "%", "#", or globs.
    home = vim.fn.expand(token)
    if type(home) ~= "string" or home == "" or home == token or home:sub(1, 1) == "~" then
      return nil, "Artefact directory " .. token .. " could not be expanded"
    end
    rest = tail
  end
  if type(home) ~= "string" or home == "" or home:sub(1, 1) == "~" then
    return nil, "Artefact directory ~ could not be expanded"
  end
  local expanded_rest, err = expand_vars(rest)
  if not expanded_rest then
    return nil, err
  end
  local joined = home:gsub("/+$", "") .. expanded_rest
  if joined:sub(1, 1) == "~" then
    return nil, "Artefact directory ~ could not be expanded"
  end
  return joined
end

-- @return string|nil expanded, string|nil warning
local function expand_configured_dir(dir)
  if dir:find("[%*%?%[]") then
    return nil, "Artefact directory contains a glob character: " .. dir
  end

  if dir:sub(1, 1) == "~" then
    return expand_leading_tilde(dir)
  end

  local expanded, err = expand_vars(dir)
  if not expanded then
    return nil, err
  end
  -- A $VAR value may itself be "~user/...". Expand that before
  -- vim.fs.normalize, which would paste the current home onto the rest.
  if expanded:sub(1, 1) == "~" then
    return expand_leading_tilde(expanded)
  end
  return expanded
end

-- Global cwd. getcwd() with no arguments follows a window-local :lcd.
local function global_cwd()
  local cwd = vim.fn.getcwd(-1, -1)
  if type(cwd) ~= "string" or cwd == "" then
    return ""
  end
  return strip_trailing_slash(cwd)
end

-- Window/tab cwd (:lcd / :tcd). A new :! or termopen inherits this process cwd.
local function effective_cwd()
  local cwd = vim.fn.getcwd()
  if type(cwd) ~= "string" or cwd == "" then
    return ""
  end
  return strip_trailing_slash(cwd)
end

-- Collapse "." / ".." and duplicate slashes. Does not resolve symlinks and
-- does not expand environment variables. A leading "~" is returned unchanged
-- so vim.fs.normalize cannot paste the current home onto "~user".
local function lexical_normalize(path)
  if type(path) ~= "string" or path == "" then
    return "."
  end
  if path:sub(1, 1) == "~" then
    return path
  end
  local norm = vim.fs.normalize(path, { expand_env = false })
  if type(norm) ~= "string" or norm == "" then
    return "."
  end
  return strip_trailing_slash(norm)
end

-- Absolute form of the expanded setting, after lexical normalize.
-- A relative setting is joined to the global cwd.
local function lexical_absolute(expanded)
  local norm = lexical_normalize(expanded)
  if vim.fn.isabsolutepath(norm) == 0 and norm ~= "/" then
    local cwd = global_cwd()
    if cwd ~= "" then
      norm = lexical_normalize(cwd .. "/" .. norm)
    end
  end
  return norm
end

-- Lexical identity, or both realpaths exist and name the same directory.
-- A missing realpath is not a match. "." is not a directory identity.
local function same_directory(a, b)
  if type(a) ~= "string" or a == "" or type(b) ~= "string" or b == "" then
    return false
  end
  local la = lexical_normalize(a)
  local lb = lexical_normalize(b)
  if la ~= "" and la ~= "." and la == lb then
    return true
  end
  local ra = vim.uv.fs_realpath(a)
  local rb = vim.uv.fs_realpath(b)
  if type(ra) ~= "string" or ra == "" or type(rb) ~= "string" or rb == "" then
    return false
  end
  ra = lexical_normalize(ra)
  rb = lexical_normalize(rb)
  return ra ~= "" and ra ~= "." and ra == rb
end

-- True when `path` is `root` or the realpath of `root`.
-- `path` is already normalized. A missing realpath is not a match.
-- "." is not a directory identity. This is the cwd check's identity.
local function directory_is(path, root)
  if type(path) ~= "string" or path == "" or path == "." or path == "/" then
    return false
  end
  if type(root) ~= "string" or root == "" then
    return false
  end
  root = lexical_normalize(root)
  if root == "" or root == "." then
    return false
  end
  if path == root then
    return true
  end
  local real = vim.uv.fs_realpath(root)
  if type(real) ~= "string" or real == "" then
    return false
  end
  local real_norm = lexical_normalize(real)
  return real_norm ~= "" and real_norm ~= "." and path == real_norm
end

-- True when `path` is the global cwd or the realpath of that cwd.
local function directory_is_global_cwd(path)
  return directory_is(path, global_cwd())
end

-- True when `path` is the home directory or the realpath of that home.
local function directory_is_home(path)
  local home = vim.uv.os_homedir()
  if type(home) ~= "string" or home == "" then
    return false
  end
  return directory_is(path, home)
end

-- Lexical path, or an existing symlink whose realpath is that directory.
local function path_is_home(path)
  if directory_is_home(path) then
    return true
  end
  local real = vim.uv.fs_realpath(path)
  if type(real) ~= "string" or real == "" then
    return false
  end
  local norm = lexical_normalize(real)
  return norm ~= "" and norm ~= "." and directory_is_home(norm)
end

-- Relative text to insert, or nil when the expanded path is absolute or
-- contains a "." / ".." segment. Duplicate slashes are already collapsed.
local function relative_insert_dir(expanded)
  if vim.fn.isabsolutepath(expanded) == 1 or has_dot_segment(expanded) then
    return nil
  end
  local relative = lexical_normalize(expanded)
  if relative == "" or relative == "." or relative == "/" or has_dot_segment(relative) then
    return nil
  end
  if vim.fn.isabsolutepath(relative) == 1 then
    return nil
  end
  return relative
end

-- nvim_buf_set_text rejects these. Spaces stay; they do not break the insert.
local function has_break_byte(path)
  return type(path) == "string"
    and (path:find("\0", 1, true) or path:find("\r", 1, true) or path:find("\n", 1, true))
end

-- @return boolean refused (already notified)
local function refuse_break_byte(path)
  if not has_break_byte(path) then
    return false
  end
  util.notify(
    "Artefact directory contains a newline, carriage return, or NUL",
    vim.log.levels.WARN
  )
  return true
end

-- True unless the setting explicitly disables artefacts: `artefacts = false`,
-- or a table whose `dir` is "" (like prompts.dir) or false. A non-string
-- truthy dir stays enabled so the resolver can warn about it.
-- Used by the setup gate and by the resolver, so both agree on "disabled".
-- @param config table|nil
-- @return boolean
function M.is_enabled(config)
  local cfg = config and config.artefacts
  if cfg == nil or cfg == true then
    return true
  end
  if cfg == false then
    return false
  end
  if type(cfg) == "table" and (cfg.dir == "" or cfg.dir == false) then
    return false
  end
  return true
end

-- @return { lexical_abs: string, relative: string|nil }|nil
-- Nil when the setting is refused (the caller is notified).
local function resolve_artefacts_dir(cfg)
  if not M.is_enabled(cfg) then
    -- Both spellings land here: artefacts = false, and dir = "" / dir = false.
    util.notify(
      "Artefacts are disabled (artefacts.dir is empty or false)",
      vim.log.levels.WARN
    )
    return nil
  end
  local dir = cfg and cfg.artefacts and cfg.artefacts.dir
  if dir == nil then
    dir = DEFAULT_DIR
  elseif type(dir) ~= "string" then
    util.notify("Artefact directory must be a string", vim.log.levels.WARN)
    return nil
  end
  local expanded, err = expand_configured_dir(dir)
  if not expanded then
    util.notify(err, vim.log.levels.WARN)
    return nil
  end
  if refuse_break_byte(expanded) then
    return nil
  end
  local lexical_abs = lexical_absolute(expanded)
  if refuse_break_byte(lexical_abs) then
    return nil
  end
  if lexical_abs == "/" then
    util.notify("Artefact directory resolves to /", vim.log.levels.WARN)
    return nil
  end
  if directory_is_global_cwd(lexical_abs) then
    util.notify("Artefact directory resolves to the working directory", vim.log.levels.WARN)
    return nil
  end
  -- Before mkdir. Bare "~" / "~/" and a symlink whose realpath is home
  -- are the home directory; "~/something" is not.
  if path_is_home(lexical_abs) then
    util.notify("Artefact directory resolves to the home directory", vim.log.levels.WARN)
    return nil
  end
  return {
    lexical_abs = lexical_abs,
    relative = relative_insert_dir(expanded),
  }
end

-- Directory actually reserved: realpath of the lexical absolute path when
-- that succeeds, otherwise the lexical path itself.
local function reserved_directory(lexical_abs)
  local real = vim.uv.fs_realpath(lexical_abs)
  if type(real) == "string" and real ~= "" then
    local norm = lexical_normalize(real)
    if norm ~= "" and norm ~= "." then
      return norm
    end
  end
  return lexical_abs
end

-- Relative form only when it is the directory that was reserved and the
-- effective cwd (:lcd / :tcd) is still the global cwd that relative text is
-- resolved against. A symlink (realpath differs), an absolute setting, a
-- "." / ".." segment, or a different window/tab directory uses the canonical
-- absolute directory instead.
local function shown_directory(info, reserved)
  if info.relative
    and reserved == info.lexical_abs
    and same_directory(effective_cwd(), global_cwd())
  then
    return info.relative
  end
  return reserved
end

-- Lexical absolute path: collapse "." / ".." and duplicate slashes.
-- Does not resolve symlinks and does not expand environment variables.
local function normalized_absolute(path)
  local abs = vim.fn.fnamemodify(path, ":p")
  if type(abs) ~= "string" or abs == "" then
    return path
  end
  return lexical_normalize(abs)
end

-- @return string|nil reserved directory, string|nil path to insert
-- Nil when mkdir fails, the setting is refused, or the reserved directory is /.
local function ensure_artefacts_dir(config)
  local info = resolve_artefacts_dir(config)
  if not info then
    return nil
  end
  pcall(vim.fn.mkdir, info.lexical_abs, "p")
  if vim.fn.isdirectory(info.lexical_abs) ~= 1 then
    util.notify("Failed to create artefacts directory: " .. info.lexical_abs, vim.log.levels.ERROR)
    return nil
  end
  local reserved = reserved_directory(info.lexical_abs)
  -- The realpath is what is inserted, and a symlink target can name bytes the
  -- lexical path did not. Re-check after the realpath.
  if refuse_break_byte(reserved) then
    return nil
  end
  if reserved == "/" then
    util.notify("Artefact directory resolves to /", vim.log.levels.WARN)
    return nil
  end
  -- A symlink can lexical-normalize somewhere else and still realpath to the cwd.
  if directory_is_global_cwd(reserved) then
    util.notify("Artefact directory resolves to the working directory", vim.log.levels.WARN)
    return nil
  end
  if path_is_home(reserved) then
    util.notify("Artefact directory resolves to the home directory", vim.log.levels.WARN)
    return nil
  end
  -- An existing directory is not success when the agent cannot create the file.
  -- Creating a file needs write and execute. nil/error from fs_access is not
  -- a refusal; listing may still read it.
  if vim.uv.fs_access(reserved, "WX") == false then
    util.notify("Artefact directory is not writable: " .. reserved, vim.log.levels.WARN)
    return nil
  end
  return reserved, shown_directory(info, reserved)
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
  -- Format characters become "-" before runs of hyphens are collapsed.
  name = replace_unicode_format(name)
  name = vim.trim(name)
  if name == "" then
    return nil
  end

  -- Leading dots go before the extension split, so ".notes" becomes
  -- "notes.md" and ".notes.json" keeps ".json". "." and ".." reduce to
  -- nothing and are refused below.
  name = name:gsub("^%.+", "")
  if name == "" then
    return nil
  end

  name = name:gsub("%s+", "-")
  -- Characters an unquoted shell treats as expansion, quoting, globbing, or
  -- command separators are replaced too. Spaces are already handled above.
  -- Other punctuation ("%", "=", "~", "#", "@", ",") is left as it was.
  name = name:gsub("[%z%c/\\:*?\"<>|$`&;()'!%[%]{}]", "-")
  name = name:gsub("%-+", "-")

  -- The extension is taken before the trailing stem strip below, so a real
  -- extension stays an extension instead of folding into the stem.
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

-- Basenames of every named buffer, collected with string operations only (no
-- syscalls). Candidate filenames differ only by their "_N" suffix, so a
-- collision is possible only with a buffer whose basename is exactly the
-- candidate filename.
-- @return table<string, string[]> basename -> raw buffer names
local function buffer_names_by_basename()
  local by_base = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" then
        local base = vim.fs.basename(name)
        if base and base ~= "" then
          local names = by_base[base]
          if not names then
            names = {}
            by_base[base] = names
          end
          names[#names + 1] = name
        end
      end
    end
  end
  return by_base
end

-- Add the paths that name `name` for reservation purposes.
-- The normalized absolute name always counts. When the buffer file does not
-- exist, also count realpath(parent) + basename so ".." and symlinks match
-- the canonical directory. fnamemodify(..., ":p") alone does neither.
-- Only called for a name whose basename matched a candidate, so the syscalls
-- below are proportional to matching names, not to the session's buffers.
local function add_buffer_reservation_paths(taken, names)
  for _, name in ipairs(names) do
    local norm = normalized_absolute(name)
    taken[norm] = true
    if vim.uv.fs_lstat(norm) == nil then
      local parent = vim.fs.dirname(norm)
      local base = vim.fs.basename(norm)
      if parent and parent ~= "" and base and base ~= "" then
        local real_parent = vim.uv.fs_realpath(parent)
        if type(real_parent) == "string" and real_parent ~= "" then
          taken[normalized_absolute(real_parent .. "/" .. base)] = true
        end
      end
    end
  end
end

local function canonical_file(dir, filename)
  return normalized_absolute(dir .. "/" .. filename)
end

-- "taken", "free", or "error". ENOENT is free. Any other lstat failure
-- (ENAMETOOLONG, EACCES, …) is an error so it cannot look like a free name.
-- A successful lstat is taken for every dirent, including a broken symlink.
local function reservation_state(abs, buffer_paths)
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
  if buffer_paths[abs] then
    return "taken"
  end
  return "free"
end

local function release_reservation(abs)
  if type(abs) == "string" then
    reserved_paths[abs] = nil
  end
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
-- On success the second return is the canonical absolute path that was reserved.
-- On failure the second return is a warning. The file is not created.
-- @param dir string canonical artefacts directory
-- @param normalized string filename from normalize_name
-- @return string|nil basename
-- @return string|nil absolute path, or a warning when no name is returned
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
  local full_stem = stem
  stem = truncate_utf8(stem, NAME_MAX - fixed)
  if stem == "" then
    return nil, "Artefact filename is too long"
  end
  local shortened = stem ~= full_stem

  local function named(suffix)
    return stamp .. "_" .. stem .. suffix .. ext
  end

  local buffer_names = buffer_names_by_basename()
  local buffer_paths = {}
  for n = 0, MAX_COLLISION_SUFFIX do
    local filename = named(n == 0 and "" or ("_" .. n))
    -- Basename-driven: only a buffer that can actually collide pays for
    -- fnamemodify / fs_lstat / fs_realpath. A buffer named "..._1.md" is
    -- caught by the candidate named "..._1.md", because each candidate is
    -- looked up under its own basename.
    local matching_buffers = buffer_names[filename]
    if matching_buffers then
      add_buffer_reservation_paths(buffer_paths, matching_buffers)
    end
    local abs = canonical_file(dir, filename)
    local state, err = reservation_state(abs, buffer_paths)
    if state == "error" then
      return nil, "Could not check artefact path: " .. tostring(err)
    end
    if state == "free" then
      if shortened then
        util.notify(
          "Artefact name was shortened to fit the filename limit",
          vim.log.levels.WARN
        )
      end
      reserved_paths[abs] = true
      return filename, abs
    end
  end
  return nil, "Could not find a free artefact filename"
end

-- Path to insert. Relative only when that directory is the one reserved.
-- Creates the directory. Does not create the file.
-- The second return is the reserved canonical path; release it if insert fails.
-- @param raw_name string
-- @return string|nil link
-- @return string|nil reserved absolute path
local function build_artefact_link(config, raw_name)
  local normalized = normalize_name(raw_name)
  if not normalized then
    util.notify("Artefact name is not a valid filename", vim.log.levels.WARN)
    return nil
  end
  local dir, shown = ensure_artefacts_dir(config)
  if not dir or not shown then
    return nil
  end
  local filename, abs_or_err = unique_artefact_filename(dir, normalized)
  if not filename then
    util.notify(abs_or_err, vim.log.levels.WARN)
    return nil
  end
  return shown .. "/" .. filename, abs_or_err
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
  -- Normal mode sits on a character. On the last one, insert after it so
  -- that character is not pushed past the path. An empty line stays at 0.
  if #line > 0 and col < #line then
    local rel = vim.str_utf_start(line, #line)
    if type(rel) == "number" then
      local last_col = #line + math.min(rel, 0) - 1
      if col == last_col then
        col = #line
      end
    end
  end
  -- Keep the path its own token. One space on a side whose neighboring
  -- character exists and is not whitespace. The start and end of the line add
  -- nothing, and an empty line stays exactly the path.
  local prefix, suffix = "", ""
  if col > 0 then
    -- Byte `col` (1-based) ends the preceding character; the offset is
    -- negative when that byte is a continuation byte.
    local rel = vim.str_utf_start(line, col)
    local before = type(rel) == "number" and line:sub(col + math.min(rel, 0), col)
      or line:sub(col, col)
    if not is_space_char(before) then
      prefix = " "
    end
  end
  if col < #line then
    -- Byte `col + 1` starts the following character; the offset counts the
    -- remaining bytes of that character.
    local rel = vim.str_utf_end(line, col + 1)
    local at = type(rel) == "number" and line:sub(col + 1, col + 1 + math.max(rel, 0))
      or line:sub(col + 1, col + 1)
    if not is_space_char(at) then
      suffix = " "
    end
  end
  text = prefix .. text .. suffix

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
    local link, reserved = build_artefact_link(config, raw)
    if not link then
      return nil
    end
    if not insert_text_at_cursor(link, loc, cursor, winid) then
      -- set_text failed, or the buffer is gone / no longer modifiable.
      release_reservation(reserved)
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

-- Collision suffix "_N" immediately before the last extension, else 0.
-- Base is the filename with that "_N" removed, so "_10" and "_2" share a base.
local function collision_base_and_suffix(filename)
  local base, n, ext = filename:match("^(.*)_(%d+)(%.[^%.]+)$")
  if base and n and ext then
    return base .. ext, tonumber(n)
  end
  return filename, 0
end

-- Regular files, plus symlinks whose target is a regular file.
-- Directories, fifos, sockets, and broken symlinks are omitted so preview
-- cannot block on a fifo.
-- @return boolean listed
-- @return table|nil stat of the file that would be read (the link target for
-- a symlink, so its mtime matches what getftime would report)
local function is_listed_artefact(name, fullpath)
  if name == "" or name:sub(1, 1) == "." then
    return false
  end
  -- A newline, CR, or NUL would break a picker row. Leave the file on disk.
  if name:find("\0", 1, true) or name:find("\r", 1, true) or name:find("\n", 1, true) then
    return false
  end
  local lst = vim.uv.fs_lstat(fullpath)
  if not lst then
    return false
  end
  if lst.type == "file" then
    return true, lst
  end
  if lst.type == "link" then
    -- fs_stat follows the link; lstat describes the link itself.
    local st = vim.uv.fs_stat(fullpath)
    if st and st.type == "file" then
      return true, st
    end
  end
  return false
end

-- Newest first. A filename timestamp that round-trips beats mtime.
-- Equal timestamps: base, then higher collision suffix. A full tie is equal.
local function list_artefact_files_sorted(config)
  config = config or {}
  local info = resolve_artefacts_dir(config)
  if not info then
    return {}, nil
  end
  local dir = info.lexical_abs
  if vim.fn.isdirectory(dir) ~= 1 then
    return {}, dir
  end
  -- readdir on a mode 000 directory fails with E484 and looks like an empty list.
  -- Mode 644 still returns names; lstat on each child then fails with EACCES
  -- and every name is dropped. nil/error from fs_access is not a refusal.
  if vim.uv.fs_access(dir, "R") == false or vim.uv.fs_access(dir, "X") == false then
    util.notify("Cannot read artefacts directory: " .. dir, vim.log.levels.WARN)
    return {}, nil
  end
  dir = reserved_directory(dir)
  if dir == "/" then
    util.notify("Artefact directory resolves to /", vim.log.levels.WARN)
    return {}, nil
  end
  if directory_is_global_cwd(dir) then
    util.notify("Artefact directory resolves to the working directory", vim.log.levels.WARN)
    return {}, nil
  end

  local entries = {}
  for _, name in ipairs(vim.fn.readdir(dir)) do
    local fullpath = dir .. "/" .. name
    local listed, st = is_listed_artefact(name, fullpath)
    if listed then
      local ts = util.parse_timestamp_from_filename(name)
      if not ts then
        -- The stat already taken above, so listing does not stat every file
        -- twice. getftime stays as a fallback when it is unusable.
        local mtime = st and st.mtime and st.mtime.sec
        if type(mtime) == "number" and mtime >= 0 then
          ts = mtime
        else
          local ft = vim.fn.getftime(fullpath)
          if type(ft) == "number" and ft >= 0 then
            ts = ft
          else
            ts = 0
          end
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
    if a.base ~= b.base then
      return a.base > b.base
    end
    if a.suffix ~= b.suffix then
      return a.suffix > b.suffix
    end
    return false
  end)

  return entries, dir
end

-- Literal preview. Telescope's buffer_previewer_maker runs path_expand, which
-- rewrites "$VAR" inside an existing filename (cost_$HOME.md).
local PREVIEW_MAX_BYTES = 1024 * 1024

local function literal_preview_lines(path)
  if type(path) ~= "string" or path == "" then
    return { "No file to preview" }
  end
  local st = vim.uv.fs_stat(path)
  if not st then
    return { "File not found" }
  end
  if st.type ~= "file" then
    return { "Not a regular file" }
  end
  if type(st.size) ~= "number" or st.size > PREVIEW_MAX_BYTES then
    return { "File is too large to preview" }
  end
  if st.size == 0 then
    return { "" }
  end
  local fd = vim.uv.fs_open(path, "r", 438)
  if not fd then
    return { "File not found" }
  end
  local data = vim.uv.fs_read(fd, st.size, 0)
  vim.uv.fs_close(fd)
  if type(data) ~= "string" then
    return { "File not found" }
  end
  if data:find("\0", 1, true) then
    return { "Binary file cannot be previewed" }
  end
  return vim.split(data, "\n", { plain = true })
end

-- Open the artefacts directory in Telescope. Warns when Telescope is absent.
function M.open_artefacts_in_telescope(config)
  local ok = pcall(require, "telescope")
  if not ok then
    util.notify("telescope.nvim is required for PTArtefacts", vim.log.levels.WARN)
    return
  end

  local entries, dir = list_artefact_files_sorted(config)
  if not dir then
    return
  end
  if vim.fn.isdirectory(dir) ~= 1 then
    dir = ensure_artefacts_dir(config)
    if not dir then
      return
    end
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local previewers = require("telescope.previewers")
  local utils = require("telescope.utils")

  local results = {}
  for _, e in ipairs(entries) do
    table.insert(results, e.name)
  end

  -- path and filename are the absolute artefact path, never Telescope's
  -- basename fallback (gen_from_file uses that when the file is unreadable).
  local function entry_maker(name)
    local path = dir .. "/" .. name
    return {
      value = name,
      ordinal = name,
      filename = path,
      path = path,
      display = function(entry)
        local text, hl_group, icon = utils.transform_devicons(entry.value, entry.value, false)
        if hl_group and icon then
          return text, { { { 0, #icon + 1 }, hl_group } }
        end
        return text
      end,
    }
  end

  local chronological_sorter = util.chronological_sorter(conf.file_sorter({}))

  local artefact_previewer = previewers.new_buffer_previewer({
    title = "Artefact preview",
    -- Literal absolute path. Telescope reuses the buffer only when this name
    -- is already cached; do not pass it through path_expand or expand().
    get_buffer_by_name = function(_, entry)
      return entry and entry.path
    end,
    define_preview = function(self, entry, _status)
      local path = entry and entry.path
      -- Cache hit: Telescope has already shown the buffer for this path.
      if type(path) == "string" and path ~= "" and self.state.bufname == path then
        -- A cache hit skips Telescope's buffer-creating branch, which is the
        -- only place it sets state.winid. Fall back to the window showing the
        -- cached preview buffer so wrap still applies to the first preview
        -- after a picker is reopened.
        local winid = self.state.winid
        if not winid or not vim.api.nvim_win_is_valid(winid) then
          local bufnr = self.state.bufnr
          if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            local found = vim.fn.bufwinid(bufnr)
            if type(found) == "number" and found ~= -1 then
              winid = found
            end
          end
        end
        util.apply_wrap(winid)
        return
      end
      local lines = literal_preview_lines(path)
      local bufnr = self.state.bufnr
      pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, lines)
      -- Basename only. vim.filetype.match must not see the full path, so a
      -- name containing "$" is not passed through path_expand or expand().
      local name = entry and entry.value
      if type(name) == "string" and name ~= "" and vim.api.nvim_buf_is_valid(bufnr) then
        local ok, ft = pcall(vim.filetype.match, { filename = name, buf = bufnr })
        if ok and type(ft) == "string" and ft ~= "" then
          vim.bo[bufnr].filetype = ft
        end
      end
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
    -- Empty list means "ignore nothing" (vim.F.if_nil). 250 is Telescope's
    -- default results floor. Descending completion indexes
    -- max_results - window_height, which stays a valid 1-based row for a
    -- normal window. A directory with more than 250 files still lists all
    -- of them.
    file_ignore_patterns = {},
    temp__scrolling_limit = math.max(#results, 250),
    previewer = artefact_previewer,
    attach_mappings = function(prompt_bufnr, _map)
      -- Literal Ex args. Telescope's select_* normalizes against the process
      -- cwd and fnameescape's the result, so :lcd / :tcd opens another file
      -- and a newline can split the command.
      local function open_path(command)
        actions.close(prompt_bufnr)
        local selection = action_state.get_selected_entry()
        local path = selection and selection.path
        if type(path) == "string" and path ~= "" then
          command({ args = { path }, magic = { file = false, bar = false } })
        end
      end
      actions.select_default:replace(function()
        actions.close(prompt_bufnr)
        local selection = action_state.get_selected_entry()
        local path = selection and selection.path
        if type(path) ~= "string" or path == "" then
          return
        end
        -- :edit in the restored window replaces a terminal buffer and fails
        -- with E1513 on winfixbuf. Split above those windows instead.
        local command = vim.cmd.edit
        if util.is_protected_window(vim.api.nvim_get_current_win()) then
          command = vim.cmd.split
        end
        command({ args = { path }, magic = { file = false, bar = false } })
      end)
      actions.select_horizontal:replace(function()
        open_path(vim.cmd.new)
      end)
      actions.select_vertical:replace(function()
        open_path(vim.cmd.vnew)
      end)
      actions.select_tab:replace(function()
        open_path(vim.cmd.tabedit)
      end)
      return true
    end,
  }):find()
end

return M
