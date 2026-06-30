local M = {}

local group = vim.api.nvim_create_augroup("SendToNvim", { clear = true })
local registered_server = nil
local created_server = false
local initialized = false
local restored_from_env = false
local last_restored_state = nil
local autosave_timer = nil
local session_restored = false -- true once any restore path has fired

-- ---------------------------------------------------------------------------
-- Session auto-persistence paths
-- ---------------------------------------------------------------------------
local session_root = vim.fn.stdpath("state") .. "/sessions"

local function cwd_hash(dir)
  -- Deterministic short hash: replace / with %% to create a flat filename
  return dir:gsub("^/", ""):gsub("/", "%%")
end

local function pane_session_dir()
  local pane = vim.env.TMUX_PANE
  if not pane or pane == "" then return nil end
  return session_root .. "/pane/" .. pane
end

local function cwd_session_dir(dir)
  return session_root .. "/cwd/" .. cwd_hash(dir or vim.fn.getcwd())
end

local function state_file_in(dir)
  return dir .. "/state.json"
end

local function pid_file_in(dir)
  return dir .. "/pid"
end

local function write_pid_file(dir)
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile({ tostring(vim.fn.getpid()) }, pid_file_in(dir))
end

local function read_pid_file(dir)
  local path = pid_file_in(dir)
  if vim.fn.filereadable(path) ~= 1 then return nil end
  local lines = vim.fn.readfile(path)
  return tonumber(lines[1])
end

local function pid_is_alive(pid)
  if not pid or pid <= 0 then return false end
  return vim.uv.kill(pid, 0) == 0
end

-- Convert 0-based nvim cursor column to 1-based state column
local function cursor_col_to_state(col) return col + 1 end
-- Convert 1-based state column back to 0-based nvim cursor column
local function cursor_col_from_state(col) return math.max(0, col - 1) end

local function plugin_root()
  -- This file lives at <tmux-revive>/nvim/lua/core/send_to_nvim.lua
  local source = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(source, ":h:h:h:h")
end

local function helper_path(name)
  return plugin_root() .. "/send_to_nvim/" .. name
end

local function run_helper(args)
  local cmd = { helper_path(args[1]) }
  for i = 2, #args do
    table.insert(cmd, args[i])
  end
  vim.fn.system(cmd)
end

local function ensure_server()
  if registered_server ~= nil and registered_server ~= "" then
    return registered_server
  end

  local socket = vim.fn.stdpath("run") .. "/send-to-nvim-" .. vim.fn.getpid() .. ".sock"

  pcall(vim.uv.fs_unlink, socket)

  local server = vim.fn.serverstart(socket)
  if server == nil or server == "" then
    return nil
  end

  registered_server = server
  created_server = true
  return registered_server
end

local function has_real_ui()
  return #vim.api.nvim_list_uis() > 0
end

local function refresh_registry(server)
  if not vim.env.TMUX_PANE or vim.env.TMUX_PANE == "" then
    return
  end

  run_helper({
    "register_nvim_instance.sh",
    vim.env.TMUX_PANE,
    server,
    tostring(vim.fn.getpid()),
    vim.fn.getcwd(),
  })
end

local function write_json_file(path, payload)
  local encoded = vim.json.encode(payload)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local tmp = path .. ".tmp." .. vim.fn.getpid()
  vim.fn.writefile({ encoded }, tmp)
  os.rename(tmp, path)
end

local function read_json_file(path)
  local lines = vim.fn.readfile(path)
  return vim.json.decode(table.concat(lines, "\n"))
end

local function session_file_path_for_state(path)
  return vim.fn.fnamemodify(path, ":h") .. "/session.vim"
end

local function resolve_session_file_path(state, state_path)
  if type(state.session_file) == "string" and state.session_file ~= "" and vim.fn.filereadable(state.session_file) == 1 then
    return state.session_file
  end

  local sibling = session_file_path_for_state(state_path)
  if vim.fn.filereadable(sibling) == 1 then
    return sibling
  end

  return ""
end

local function is_supported_file_window(win)
  local buf = vim.api.nvim_win_get_buf(win)
  local name = vim.api.nvim_buf_get_name(buf)
  return name ~= "" and vim.bo[buf].buftype == ""
end

local function serialize_layout_node(layout, saved_win_indexes)
  if type(layout) ~= "table" or #layout < 2 then
    return nil
  end

  local kind = layout[1]
  if kind == "leaf" then
    local winid = layout[2]
    local saved_index = saved_win_indexes[winid]
    if saved_index == nil then
      return nil
    end
    return { kind = "leaf", win = saved_index }
  end

  local children = {}
  for _, child in ipairs(layout[2] or {}) do
    local serialized = serialize_layout_node(child, saved_win_indexes)
    if serialized ~= nil then
      table.insert(children, serialized)
    end
  end

  if #children == 0 then
    return nil
  end
  if #children == 1 then
    return children[1]
  end

  return {
    kind = kind,
    children = children,
  }
end

local function snapshot_has_only_supported_file_state(state)
  local unsupported = state.unsupported or {}
  return #(state.dirty_buffers or {}) == 0
    and #(unsupported.special_buffers or {}) == 0
    and #(unsupported.terminal_buffers or {}) == 0
    and tonumber(unsupported.quickfix_size or 0) == 0
    and #(unsupported.loclist_windows or {}) == 0
end

local function write_session_file(path)
  local original_sessionoptions = vim.o.sessionoptions
  vim.o.sessionoptions = table.concat({
    "blank",
    "buffers",
    "curdir",
    "folds",
    "help",
    "tabpages",
    "winsize",
    "localoptions",
  }, ",")
  local ok = pcall(vim.cmd, "silent! mksession! " .. vim.fn.fnameescape(path))
  vim.o.sessionoptions = original_sessionoptions
  return ok and vim.fn.filereadable(path) == 1
end

local function summarize_unsupported_state(state)
  local parts = {}
  local unsupported = state.unsupported or {}
  local special_buffers = unsupported.special_buffers or {}
  local terminal_buffers = unsupported.terminal_buffers or {}
  local quickfix_size = tonumber(unsupported.quickfix_size or 0) or 0
  local loclist_windows = unsupported.loclist_windows or {}

  if #special_buffers > 0 then
    table.insert(parts, string.format("%d special buffer(s)", #special_buffers))
  end
  if #terminal_buffers > 0 then
    table.insert(parts, string.format("%d terminal buffer(s)", #terminal_buffers))
  end
  if quickfix_size > 0 then
    table.insert(parts, string.format("quickfix list (%d item(s))", quickfix_size))
  end
  if #loclist_windows > 0 then
    table.insert(parts, string.format("%d location list window(s)", #loclist_windows))
  end

  return parts
end

-- Collapse a list of restore-limitation messages into a single, length-bounded
-- line. Embedded newlines are the strongest trigger for nvim's hit-enter prompt
-- (which freezes an unattended background pane), so they are flattened; the
-- length is bounded only to stop a pathological concatenation from becoming a
-- huge multi-screen message. The leak itself is prevented structurally by the
-- self-rearming autosave timer — this just keeps the warning well-behaved while
-- preserving the detail (dirty buffers, quickfix list, …) the user needs.
local function clamp_restore_summary(messages, max_len)
  max_len = max_len or 300
  local summary = ("send_to_nvim: restored file-backed state only; " ..
    table.concat(messages, "; ")):gsub("%s+", " ")
  if #summary > max_len then summary = summary:sub(1, max_len - 3) .. "..." end
  return summary
end

local function notify_restore_limits(state)
  local messages = {}
  local dirty_buffers = state.dirty_buffers or {}
  local unsupported_parts = summarize_unsupported_state(state)

  if #dirty_buffers > 0 then
    local recovered_count = 0
    for _, db in ipairs(dirty_buffers) do
      if type(db.recovery_path) == "string" and db.recovery_path ~= "" and vim.fn.filereadable(db.recovery_path) == 1 then
        recovered_count = recovered_count + 1
      end
    end
    if recovered_count > 0 then
      table.insert(messages, string.format(
        "%d dirty buffer(s) at snapshot time; %d recovery file(s) saved — use :DiffRecovered to review",
        #dirty_buffers, recovered_count))
    else
      table.insert(messages, string.format("%d dirty buffer(s) were present at snapshot time and were not restored", #dirty_buffers))
    end
  end

  if #unsupported_parts > 0 then
    table.insert(messages, "not restored: " .. table.concat(unsupported_parts, ", "))
  end

  if #messages > 0 then
    vim.schedule(function()
      vim.notify(clamp_restore_summary(messages), vim.log.levels.WARN)
    end)
  end
end

-- ---------------------------------------------------------------------------
-- Session auto-save: write state to both pane-keyed and cwd-keyed paths
-- ---------------------------------------------------------------------------
local function has_restorable_state()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buflisted then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" and vim.bo[buf].buftype == "" then
        return true
      end
    end
  end
  return false
end

local function autosave_session()
  if not has_real_ui() or not has_restorable_state() then return end

  local cwd = vim.fn.getcwd()
  local cwd_dir = cwd_session_dir(cwd)
  vim.fn.mkdir(cwd_dir, "p")
  M.export_restore_state(state_file_in(cwd_dir))
  write_pid_file(cwd_dir)

  local pane_dir = pane_session_dir()
  if pane_dir then
    vim.fn.mkdir(pane_dir, "p")
    M.export_restore_state(state_file_in(pane_dir))
    write_pid_file(pane_dir)
  end
end

-- Autosave pacing (env-overridable; matches TMUX_MANAGE_* convention).
-- The delay before each save is set proportional to how long the *previous*
-- save took, clamped to [min, max], so cheap saves stay frequent while a heavy
-- session backs off automatically. Overhead targets ~1/autosave_overhead of
-- wall-clock spent saving.
local function env_secs(name, default)
  local v = tonumber(vim.env[name] or "")
  return (v and v > 0) and v or default
end

-- Append a diagnostic line to TMUX_MANAGE_NVIM_LOG when set. Off by default, and
-- a plain file append — never an echo/notify — so it cannot raise the hit-enter
-- prompt that this whole subsystem is hardened against.
local function log_debug(msg)
  local path = vim.env.TMUX_MANAGE_NVIM_LOG
  if not path or path == "" then return end
  pcall(function()
    local fh = io.open(path, "a")
    if not fh then return end
    fh:write(os.date("!%Y-%m-%dT%H:%M:%SZ ") .. msg .. "\n")
    fh:close()
  end)
end
local autosave_min_ms   = env_secs("TMUX_MANAGE_NVIM_AUTOSAVE_MIN_SECS", 60) * 1000
local autosave_max_ms   = env_secs("TMUX_MANAGE_NVIM_AUTOSAVE_MAX_SECS", 600) * 1000
local autosave_overhead = 50

local function next_autosave_ms(last_ms)
  return math.max(autosave_min_ms, math.min(autosave_max_ms, last_ms * autosave_overhead))
end

-- run_fn is an optional injection seam for tests; production passes nothing and
-- the real autosave_session is used.
local function start_autosave_timer(run_fn)
  if autosave_timer then return end
  run_fn = run_fn or autosave_session
  autosave_timer = vim.uv.new_timer()
  -- Self-rearming one-shot timer: the next countdown begins only after the
  -- previous save has actually run, so a busy/wedged main loop can never stack
  -- events on the multiqueue (the cause of the multi-GB leak). pcall + the
  -- unconditional re-arm keep the loop alive even if a save throws.
  local function arm(delay_ms)
    if not autosave_timer then return end -- stopped; don't re-arm
    autosave_timer:start(delay_ms, 0, function()
      vim.schedule(function()
        if not autosave_timer then return end -- stopped between fire and now; no stray save, no re-arm
        local t0 = vim.uv.hrtime()
        local ok, err = pcall(run_fn)
        if not ok then log_debug("autosave run failed: " .. tostring(err)) end
        arm(next_autosave_ms((vim.uv.hrtime() - t0) / 1e6))
      end)
    end)
  end
  arm(autosave_min_ms)
end

local function stop_autosave_timer()
  if autosave_timer then
    autosave_timer:stop()
    autosave_timer:close()
    autosave_timer = nil
  end
end

-- ---------------------------------------------------------------------------
-- Session cleanup: sweep stale pane and cwd entries on startup
-- ---------------------------------------------------------------------------
local session_max_age_secs = 7 * 24 * 60 * 60 -- 7 days

local function sweep_stale_sessions()
  local now = os.time()

  -- Sweep pane sessions: delete any where the owning PID is dead
  local pane_root = session_root .. "/pane"
  if vim.fn.isdirectory(pane_root) == 1 then
    local pane_dirs = vim.fn.glob(pane_root .. "/*", false, true)
    for _, dir in ipairs(pane_dirs) do
      local saved_pid = read_pid_file(dir)
      if not saved_pid or not pid_is_alive(saved_pid) then
        vim.fn.delete(dir, "rf")
      end
    end
  end

  -- Sweep cwd sessions: delete where PID is dead AND state file is older than threshold
  local cwd_root = session_root .. "/cwd"
  if vim.fn.isdirectory(cwd_root) == 1 then
    local cwd_dirs = vim.fn.glob(cwd_root .. "/*", false, true)
    for _, dir in ipairs(cwd_dirs) do
      local saved_pid = read_pid_file(dir)
      if saved_pid and pid_is_alive(saved_pid) then
        goto continue
      end
      local state_path = state_file_in(dir)
      if vim.fn.filereadable(state_path) == 1 then
        local mtime = vim.fn.getftime(state_path)
        if mtime > 0 and (now - mtime) > session_max_age_secs then
          vim.fn.delete(dir, "rf")
        end
      else
        -- No state file at all, clean up
        vim.fn.delete(dir, "rf")
      end
      ::continue::
    end
  end
end

-- ---------------------------------------------------------------------------
-- Session auto-restore: layered priority
-- ---------------------------------------------------------------------------
local function try_restore_from_pane()
  local pane_dir = pane_session_dir()
  if not pane_dir then return false end
  local state_path = state_file_in(pane_dir)
  if vim.fn.filereadable(state_path) ~= 1 then return false end
  -- Only restore if the owning nvim is dead (i.e. we're recovering from a crash)
  local saved_pid = read_pid_file(pane_dir)
  if saved_pid and pid_is_alive(saved_pid) then return false end
  return M.restore_from_state_file(state_path)
end

local function try_restore_from_cwd()
  local cwd_dir = cwd_session_dir()
  local state_path = state_file_in(cwd_dir)
  if vim.fn.filereadable(state_path) ~= 1 then return false end
  -- Don't restore if another nvim instance owns this session
  local saved_pid = read_pid_file(cwd_dir)
  if saved_pid and pid_is_alive(saved_pid) then return false end
  return M.restore_from_state_file(state_path)
end

local function restore_from_env_if_needed()
  if restored_from_env then
    return
  end

  local restore_path = vim.env.TMUX_NVIM_RESTORE_STATE
  if type(restore_path) ~= "string" or restore_path == "" then
    -- No tmux-revive restore — try auto-persistence fallbacks
    if not session_restored then
      restored_from_env = true
      vim.schedule(function()
        if try_restore_from_pane() then
          session_restored = true
        elseif try_restore_from_cwd() then
          session_restored = true
        end
        start_autosave_timer()
      end)
    end
    return
  end

  -- Unset env var so child nvim processes don't re-trigger restore
  vim.env.TMUX_NVIM_RESTORE_STATE = nil
  restored_from_env = true
  vim.schedule(function()
    M.restore_from_state_file(restore_path)
    session_restored = true
    start_autosave_timer()
  end)
end

function M.export_restore_state(path)
  if type(path) ~= "string" or path == "" then
    return 0
  end

  local state = {
    cwd = vim.fn.getcwd(),
    current_tab = vim.fn.tabpagenr(),
    tabs = {},
    session_file = "",
    dirty_buffers = {},
    unsupported = {
      special_buffers = {},
      terminal_buffers = {},
      quickfix_size = 0,
      loclist_windows = {},
    },
  }

  local dirty_buffers_dir = vim.fn.fnamemodify(path, ":h") .. "/dirty-buffers"
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buflisted and vim.bo[buf].modified then
      local bufname = vim.api.nvim_buf_get_name(buf)
      local entry = {
        name = bufname,
        modified = true,
      }
      -- Save dirty buffer content for recovery (cap at 100k lines to avoid OOM)
      if bufname ~= "" and vim.bo[buf].buftype == "" then
        local line_count = vim.api.nvim_buf_line_count(buf)
        local max_lines = 100000
        if line_count <= max_lines then
          local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
          if #lines > 0 then
            local safe_name = bufname:gsub("[/\\]", "%%"):sub(1, 200) .. "-" .. buf
            local recovery_path = dirty_buffers_dir .. "/" .. safe_name .. ".recovered"
            vim.fn.mkdir(dirty_buffers_dir, "p")
            pcall(vim.fn.writefile, lines, recovery_path)
            entry.recovery_path = recovery_path
          end
        else
          entry.skipped_recovery = true
          entry.line_count = line_count
        end
      end
      table.insert(state.dirty_buffers, entry)
    end

    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buflisted and vim.bo[buf].buftype ~= "" then
      local item = {
        name = vim.api.nvim_buf_get_name(buf),
        buftype = vim.bo[buf].buftype,
      }
      table.insert(state.unsupported.special_buffers, item)
      if vim.bo[buf].buftype == "terminal" then
        table.insert(state.unsupported.terminal_buffers, item)
      end
    end
  end

  state.unsupported.quickfix_size = tonumber(vim.fn.getqflist({ size = 0 }).size or 0) or 0

  -- Capture full quickfix list entries (capped at 500 to avoid bloating snapshots)
  local qf_max = 500
  local qf_all = vim.fn.getqflist({ all = 1 })
  if type(qf_all) == "table" and type(qf_all.items) == "table" and #qf_all.items > 0 then
    local qf_entries = {}
    for i, item in ipairs(qf_all.items) do
      if i > qf_max then break end
      local filename = ""
      if item.bufnr and item.bufnr > 0 then
        filename = vim.api.nvim_buf_get_name(item.bufnr)
      end
      table.insert(qf_entries, {
        filename = filename,
        lnum = item.lnum or 0,
        col = item.col or 0,
        text = item.text or "",
        type = item.type or "",
      })
    end
    state.quickfix = {
      title = qf_all.title or "",
      items = qf_entries,
    }
  end

  for tab_index, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
    local wins = {}
    local current_win_index = 1
    local saved_win_indexes = {}
    local current_tab_win = vim.api.nvim_tabpage_get_win(tabpage)

    for win_index, win in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
      local buf = vim.api.nvim_win_get_buf(win)
      local name = vim.api.nvim_buf_get_name(buf)
      local cursor = vim.api.nvim_win_get_cursor(win)

      local loclist_size = tonumber(vim.fn.getloclist(win, { size = 0 }).size or 0) or 0
      if loclist_size > 0 then
        table.insert(state.unsupported.loclist_windows, {
          tab = tab_index,
          win = win_index,
          size = loclist_size,
        })
      end

      if name ~= "" and vim.bo[buf].buftype == "" then
        saved_win_indexes[win] = #wins + 1
        table.insert(wins, {
          path = vim.fs.normalize(name),
          cursor = { cursor[1], cursor_col_to_state(cursor[2]) },
          width = vim.api.nvim_win_get_width(win),
          height = vim.api.nvim_win_get_height(win),
        })
        if win == current_tab_win then
          current_win_index = #wins
        end

        -- Capture full location list entries per supported window (capped at 200)
        -- Uses saved_win_indexes index so restore maps to the correct window
        if loclist_size > 0 then
          local loc_max = 200
          local loc_all = vim.fn.getloclist(win, { all = 1 })
          if type(loc_all) == "table" and type(loc_all.items) == "table" then
            local loc_entries = {}
            for li, item in ipairs(loc_all.items) do
              if li > loc_max then break end
              local filename = ""
              if item.bufnr and item.bufnr > 0 then
                filename = vim.api.nvim_buf_get_name(item.bufnr)
              end
              table.insert(loc_entries, {
                filename = filename,
                lnum = item.lnum or 0,
                col = item.col or 0,
                text = item.text or "",
                type = item.type or "",
              })
            end
            if #loc_entries > 0 then
              state.loclists = state.loclists or {}
              table.insert(state.loclists, {
                tab = tab_index,
                win = saved_win_indexes[win],
                title = loc_all.title or "",
                items = loc_entries,
              })
            end
          end
        end
      end
    end

    table.insert(state.tabs, {
      index = tab_index,
      current_win = current_win_index,
      layout = serialize_layout_node(vim.fn.winlayout(tab_index), saved_win_indexes),
      wins = wins,
    })
  end

  if snapshot_has_only_supported_file_state(state) then
    local session_file = session_file_path_for_state(path)
    if write_session_file(session_file) then
      state.session_file = session_file
    end
  end

  write_json_file(path, state)
  return 1
end

local function apply_saved_positions_to_restored_tabs(state)
  local tabs = vim.api.nvim_list_tabpages()

  for tab_index, tab_state in ipairs(state.tabs or {}) do
    local tabpage = tabs[tab_index]
    if tabpage ~= nil then
      local wins = vim.api.nvim_tabpage_list_wins(tabpage)
      for win_index, win_state in ipairs(tab_state.wins or {}) do
        local win = wins[win_index]
        if win ~= nil then
          local path = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
          if type(win_state.path) == "string" and win_state.path ~= "" and path == win_state.path then
            if type(win_state.cursor) == "table" and #win_state.cursor >= 2 then
              pcall(vim.api.nvim_win_set_cursor, win, { win_state.cursor[1], cursor_col_from_state(win_state.cursor[2]) })
            end
          end
        end
      end
    end
  end
end

local function restore_from_session_file(state, state_path)
  if not snapshot_has_only_supported_file_state(state) then
    return false
  end

  local session_file = resolve_session_file_path(state, state_path)
  if session_file == "" then
    return false
  end

  pcall(vim.cmd, "silent! %bwipeout!")
  local ok = pcall(vim.cmd, "silent! source " .. vim.fn.fnameescape(session_file))
  if not ok then
    return false
  end
  if #(vim.api.nvim_list_tabpages()) == 0 then
    return false
  end

  apply_saved_positions_to_restored_tabs(state)
  return true
end

-- Recursively restore a layout node into `base_win`.
-- Creates splits at the correct tree level so nested mixed layouts
-- (e.g. row[col[A,B], C]) produce the right topology.
-- Returns a map of saved_win_index -> nvim_win_id.
local function restore_layout_node(node, tab_state, base_win)
  local created_wins = {}

  if type(node) ~= "table" then
    return created_wins
  end

  if node.kind == "leaf" then
    local win_state = tab_state.wins[node.win]
    if type(win_state) == "table" and type(win_state.path) == "string" and win_state.path ~= "" then
      vim.api.nvim_set_current_win(base_win)
      vim.cmd("edit " .. vim.fn.fnameescape(win_state.path))
      created_wins[node.win] = base_win
      if type(win_state.cursor) == "table" and #win_state.cursor >= 2 then
        pcall(vim.api.nvim_win_set_cursor, base_win, { win_state.cursor[1], cursor_col_from_state(win_state.cursor[2]) })
      end
    end
    return created_wins
  end

  local children = node.children or {}
  if #children == 0 then return created_wins end

  local split_cmd = node.kind == "col" and "split" or "vsplit"

  -- Create N-1 splits from base_win for all children.
  -- With splitright/splitbelow=true, successive splits from the same window
  -- insert new windows between base_win and earlier splits (reverse visual order),
  -- so we reverse the collected windows to match child order.
  local new_wins = {}
  for _ = 2, #children do
    vim.api.nvim_set_current_win(base_win)
    vim.cmd(split_cmd)
    table.insert(new_wins, vim.api.nvim_get_current_win())
  end

  local child_wins = { base_win }
  for i = #new_wins, 1, -1 do
    table.insert(child_wins, new_wins[i])
  end

  for i, child in ipairs(children) do
    if child_wins[i] then
      local sub = restore_layout_node(child, tab_state, child_wins[i])
      for k, v in pairs(sub) do
        created_wins[k] = v
      end
    end
  end

  return created_wins
end

local function restore_tab_from_state(tab_state, is_first_tab)
  if type(tab_state) ~= "table" or type(tab_state.wins) ~= "table" or #tab_state.wins == 0 then
    return
  end

  if not is_first_tab then
    vim.cmd("tabnew")
  end

  local created_wins = {}

  if type(tab_state.layout) == "table" and tab_state.layout.kind then
    -- Layout-aware restore: recursively create splits matching saved topology.
    -- Force splitright/splitbelow for deterministic window ordering.
    local saved_splitright = vim.o.splitright
    local saved_splitbelow = vim.o.splitbelow
    vim.o.splitright = true
    vim.o.splitbelow = true

    created_wins = restore_layout_node(tab_state.layout, tab_state, vim.api.nvim_get_current_win())

    vim.o.splitright = saved_splitright
    vim.o.splitbelow = saved_splitbelow
  else
    -- Legacy fallback: vsplit all windows sequentially
    for index, win_state in ipairs(tab_state.wins) do
      if type(win_state.path) == "string" and win_state.path ~= "" then
        if index == 1 then
          vim.cmd("edit " .. vim.fn.fnameescape(win_state.path))
        else
          vim.cmd("vsplit " .. vim.fn.fnameescape(win_state.path))
        end
        created_wins[index] = vim.api.nvim_get_current_win()
        if type(win_state.cursor) == "table" and #win_state.cursor >= 2 then
          pcall(vim.api.nvim_win_set_cursor, 0, { win_state.cursor[1], cursor_col_from_state(win_state.cursor[2]) })
        end
      end
    end
  end

  -- E7: Restore window sizes after all splits are created
  for win_idx, win_handle in pairs(created_wins) do
    local win_state = tab_state.wins[win_idx]
    if type(win_state) == "table" and vim.api.nvim_win_is_valid(win_handle) then
      if type(win_state.width) == "number" and win_state.width > 0 then
        pcall(vim.api.nvim_win_set_width, win_handle, win_state.width)
      end
      if type(win_state.height) == "number" and win_state.height > 0 then
        pcall(vim.api.nvim_win_set_height, win_handle, win_state.height)
      end
    end
  end

  local current_win = tonumber(tab_state.current_win or 1) or 1
  if created_wins[current_win] ~= nil then
    pcall(vim.api.nvim_set_current_win, created_wins[current_win])
  end
end

local function restore_quickfix_and_loclists(state)
  -- Restore quickfix list
  if type(state.quickfix) == "table" and type(state.quickfix.items) == "table" and #state.quickfix.items > 0 then
    local qf_items = {}
    for _, entry in ipairs(state.quickfix.items) do
      table.insert(qf_items, {
        filename = entry.filename or "",
        lnum = entry.lnum or 0,
        col = entry.col or 0,
        text = entry.text or "",
        type = entry.type or "",
      })
    end
    pcall(vim.fn.setqflist, {}, " ", {
      title = state.quickfix.title or "",
      items = qf_items,
    })
  end

  -- Restore location lists
  if type(state.loclists) ~= "table" then return end
  local tabs = vim.api.nvim_list_tabpages()
  for _, loc_state in ipairs(state.loclists) do
    local tab_idx = loc_state.tab or 0
    local win_idx = loc_state.win or 0
    local tabpage = tabs[tab_idx]
    if tabpage then
      local wins = vim.api.nvim_tabpage_list_wins(tabpage)
      local win = wins[win_idx]
      if win then
        local loc_items = {}
        for _, entry in ipairs(loc_state.items or {}) do
          table.insert(loc_items, {
            filename = entry.filename or "",
            lnum = entry.lnum or 0,
            col = entry.col or 0,
            text = entry.text or "",
            type = entry.type or "",
          })
        end
        pcall(vim.fn.setloclist, win, {}, " ", {
          title = loc_state.title or "",
          items = loc_items,
        })
      end
    end
  end
end

function M.restore_from_state_file(path)
  if type(path) ~= "string" or path == "" or vim.fn.filereadable(path) ~= 1 then
    return false
  end

  local ok, state = pcall(read_json_file, path)
  if not ok or type(state) ~= "table" then
    return false
  end

  if type(state.cwd) == "string" and state.cwd ~= "" and vim.fn.isdirectory(state.cwd) == 1 then
    pcall(vim.cmd, "cd " .. vim.fn.fnameescape(state.cwd))
  end

  if type(state.tabs) ~= "table" or #state.tabs == 0 then
    return true
  end

  if restore_from_session_file(state, path) then
    local created_tabs = vim.api.nvim_list_tabpages()
    local current_tab = tonumber(state.current_tab or 1) or 1
    if created_tabs[current_tab] ~= nil then
      pcall(vim.api.nvim_set_current_tabpage, created_tabs[current_tab])
      local tab_state = state.tabs[current_tab]
      if type(tab_state) == "table" then
        local wins = vim.api.nvim_tabpage_list_wins(created_tabs[current_tab])
        local current_win = tonumber(tab_state.current_win or 1) or 1
        if wins[current_win] ~= nil then
          pcall(vim.api.nvim_set_current_win, wins[current_win])
        end
      end
    end
    restore_quickfix_and_loclists(state)
    last_restored_state = state
    notify_restore_limits(state)
    return true
  end

  pcall(vim.cmd, "silent! %bwipeout!")

  local created_tabs = {}
  for tab_index, tab_state in ipairs(state.tabs) do
    restore_tab_from_state(tab_state, tab_index == 1)
    table.insert(created_tabs, vim.api.nvim_get_current_tabpage())
  end

  local current_tab = tonumber(state.current_tab or 1) or 1
  if created_tabs[current_tab] ~= nil then
    pcall(vim.api.nvim_set_current_tabpage, created_tabs[current_tab])
  end

  restore_quickfix_and_loclists(state)
  last_restored_state = state
  notify_restore_limits(state)

  return true
end

function M.remote_open(target)
  if type(target) ~= "table" or type(target.path) ~= "string" or target.path == "" then
    return false
  end

  if not target.path:match("^/") then
    vim.notify("send_to_nvim: refused non-absolute path: " .. target.path, vim.log.levels.ERROR)
    return false
  end

  local absolute_path = vim.fs.normalize(target.path)
  local escaped = vim.fn.fnameescape(absolute_path)
  local ok, err = pcall(vim.cmd, "tab drop " .. escaped)
  local current_path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p")

  if current_path ~= absolute_path then
    if not ok and err ~= nil then
      vim.notify("send_to_nvim: failed to open " .. absolute_path .. ": " .. tostring(err), vim.log.levels.ERROR)
    end
    return false
  end

  if target.line ~= nil then
    local line = math.max(1, math.floor(tonumber(target.line) or 1))
    local col = math.max(1, math.floor(tonumber(target.col) or 1))
    pcall(vim.api.nvim_win_set_cursor, 0, { line, col - 1 })
    vim.cmd("normal! zv")
  end

  return true
end

function M.setup()
  local in_tmux = vim.env.TMUX_PANE and vim.env.TMUX_PANE ~= ""

  local function initialize()
    if initialized or not has_real_ui() then
      return
    end
    initialized = true

    sweep_stale_sessions()

    -- Skip opening nvim with explicit file args — user is opening specific files,
    -- not expecting a session restore
    local skip_restore = #vim.fn.argv() > 0

    -- tmux registry (only when inside tmux)
    local server
    if in_tmux then
      server = ensure_server()
      if server and server ~= "" then
        refresh_registry(server)
      end
    end

    -- Restore: layered priority (tmux-revive env > pane > cwd)
    if not skip_restore then
      if vim.v.vim_did_enter == 1 then
        restore_from_env_if_needed()
      else
        vim.api.nvim_create_autocmd("VimEnter", {
          group = group,
          once = true,
          callback = restore_from_env_if_needed,
        })
      end
    else
      start_autosave_timer()
    end

    vim.api.nvim_create_user_command("DiffRecovered", function()
      if not last_restored_state or not last_restored_state.dirty_buffers then
        vim.notify("No recovered dirty buffers from last restore", vim.log.levels.INFO)
        return
      end
      local opened = 0
      for _, db in ipairs(last_restored_state.dirty_buffers) do
        if type(db.recovery_path) == "string" and db.recovery_path ~= "" and vim.fn.filereadable(db.recovery_path) == 1 then
          local current_file = db.name or ""
          if current_file ~= "" and vim.fn.filereadable(current_file) == 1 then
            vim.cmd("tabnew " .. vim.fn.fnameescape(current_file))
            vim.cmd("diffthis")
            vim.cmd("vsplit " .. vim.fn.fnameescape(db.recovery_path))
            vim.cmd("diffthis")
            opened = opened + 1
          else
            vim.cmd("tabnew " .. vim.fn.fnameescape(db.recovery_path))
            vim.notify("Original file missing: " .. (current_file ~= "" and current_file or "(unnamed)") .. " — showing recovery file only", vim.log.levels.WARN)
            opened = opened + 1
          end
        end
      end
      if opened == 0 then
        vim.notify("No recovery files found on disk", vim.log.levels.INFO)
      else
        vim.notify(string.format("Opened %d recovered buffer diff(s)", opened), vim.log.levels.INFO)
      end
    end, { desc = "Open diff views for dirty buffers recovered during tmux-manage restore" })

    -- tmux registry refresh (only when inside tmux)
    if in_tmux and server and server ~= "" then
      vim.api.nvim_create_autocmd({ "FocusGained", "VimEnter", "DirChanged" }, {
        group = group,
        callback = function()
          refresh_registry(server)
        end,
      })
    end

    vim.api.nvim_create_autocmd("VimLeavePre", {
      group = group,
      once = true,
      callback = function()
        stop_autosave_timer()
        -- Normal exit: save one final snapshot then clean up pane session
        autosave_session()
        -- Clean pane-keyed session (cwd-keyed persists for future opens)
        local pane_dir = pane_session_dir()
        if pane_dir then
          vim.fn.delete(pane_dir, "rf")
        end

        if in_tmux then
          run_helper({
            "unregister_nvim_instance.sh",
            vim.env.TMUX_PANE,
            tostring(vim.fn.getpid()),
          })
        end

        if created_server and registered_server then
          pcall(vim.fn.serverstop, registered_server)
        end
      end,
    })
  end

  if has_real_ui() then
    initialize()
    return
  end

  vim.api.nvim_create_autocmd("UIEnter", {
    group = group,
    once = true,
    callback = initialize,
  })
end

-- Internals exposed for tests/*.bats only. Not part of the public API.
M.__test = {
  next_autosave_ms      = next_autosave_ms,
  env_secs              = env_secs,
  clamp_restore_summary = clamp_restore_summary,
  start_autosave_timer  = start_autosave_timer,
  stop_autosave_timer   = stop_autosave_timer,
}

return M
