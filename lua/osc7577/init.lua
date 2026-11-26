local buffers = require("osc7577.buffers")
local protocol = require("osc7577.protocol")
local session = require("osc7577.session")
local tty = require("osc7577.tty")
local util = require("osc7577.util")
local uv = vim.uv or vim.loop

local M = {}

local state = {
  did_setup = false,
  commands_created = false,
  active = false,
  disabled = false,
  started = false,
  saving = false,
  restoring = false,
  exiting = false,
  snapshot_stats = { count = 0, bytes = 0, skipped = {} },
}

local function defaults()
  return {
    enabled = true,
    command = "nvim",
    state_dir = util.join(vim.fn.stdpath("state"), "osc7577"),
    include_cwd = false,
    restore_terminals = false,
    snapshot_unsaved = true,
    retention_days = 30,
    save_debounce_ms = 2000,
    save_interval_ms = 300000,
    max_buffer_bytes = 5 * 1024 * 1024,
    max_total_bytes = 64 * 1024 * 1024,
    notify = true,
  }
end

local function notify(message, level)
  if state.config and state.config.notify and not state.exiting then
    vim.notify(message, level or vim.log.levels.INFO, { title = "osc7577.nvim" })
  end
end

local function fail(message)
  message = tostring(message)
  state.last_error = message
  if state.last_notified_error ~= message then
    notify("OSC 7577: " .. message, vim.log.levels.ERROR)
    state.last_notified_error = message
  end
  return nil, message
end

local function tty_supported()
  if state.config and state.config._force_tty ~= nil then
    return state.config._force_tty
  end
  return vim.fn.has("win32") == 0 and vim.fn.has("ttyin") == 1 and vim.fn.has("ttyout") == 1
end

local function capture_token()
  if not tty_supported() then
    state.unsupported = "Neovim must run in a terminal with TTY stdin and stdout"
    return false
  end
  if state.token then
    return true
  end

  local token = vim.env.OSC7577_TOKEN
  if not protocol.valid_token(token) then
    state.unsupported = token == nil and "OSC7577_TOKEN is not set" or "OSC7577_TOKEN is invalid"
    return false
  end
  state.token = token
  vim.env.OSC7577_TOKEN = nil
  state.unsupported = nil
  return true
end

local function stop_timer(name)
  local timer = state[name]
  if timer then
    timer:stop()
    if not timer:is_closing() then
      timer:close()
    end
    state[name] = nil
  end
end

local function stop_timers()
  stop_timer("debounce_timer")
  stop_timer("interval_timer")
end

local function can_run()
  return state.active and not state.disabled and state.token ~= nil
end

local function ensure_context()
  local id = session.managed_id(vim.v.this_session, state.config.state_dir)
  if id and not uv.fs_stat(session.context(state.config.state_dir, id).session_path) then
    id = nil
  end
  if id and (not state.ctx or state.ctx.id ~= id) then
    state.ctx = session.context(state.config.state_dir, id)
  elseif not state.ctx then
    state.ctx = session.new(state.config.state_dir)
  end
  return state.ctx
end

local function emit(report)
  local writer = state.config._writer or tty.write
  local ok, result, err = pcall(writer, report.sequence)
  if not ok then
    return fail(result)
  end
  if result == nil and err ~= nil then
    return fail(err)
  end
  state.last_report = os.time()
  state.last_error = nil
  state.last_notified_error = nil
  return true
end

local function send_clear()
  if not state.token then
    return nil, "no terminal token is available"
  end
  local report, err = protocol.clear({
    pid = util.owning_pid(),
    time = os.time(),
    token = state.token,
  })
  if not report then
    return fail(err)
  end
  return emit(report)
end

function M.report()
  if not can_run() then
    return nil, state.unsupported or "OSC 7577 is disabled"
  end
  local ctx = ensure_context()
  local report, err = protocol.report({
    pid = util.owning_pid(),
    time = os.time(),
    argv = { state.config.command, "-S", ctx.session_path },
    cwd = state.config.include_cwd and vim.fn.getcwd() or nil,
    token = state.token,
  })
  if not report then
    send_clear()
    return fail(err)
  end
  return emit(report)
end

local function save_now()
  if not can_run() then
    return nil, state.unsupported or "OSC 7577 is disabled"
  end
  if state.saving or state.restoring then
    return false
  end
  local ctx = ensure_context()
  state.saving = true

  local ok, saved, save_err = pcall(function()
    local saved_session, err = session.save(ctx, state.config.restore_terminals)
    if not saved_session then
      return nil, err
    end

    if state.config.snapshot_unsaved then
      local snapshots, stats_or_err = buffers.save(ctx, state.config)
      if not snapshots then
        state.last_error = tostring(stats_or_err)
        notify(
          "OSC 7577: session saved, but unsaved snapshots failed: " .. tostring(stats_or_err),
          vim.log.levels.ERROR
        )
      else
        state.snapshot_stats = stats_or_err
        local signature = table.concat(stats_or_err.skipped, "\n")
        if #stats_or_err.skipped > 0 and signature ~= state.last_skip_signature then
          notify("OSC 7577: some buffers were not snapshotted: " .. signature, vim.log.levels.WARN)
        end
        state.last_skip_signature = signature
      end
    end
    return true
  end)

  state.saving = false
  if not ok then
    return fail(saved)
  end
  if not saved then
    return fail(save_err)
  end

  state.last_save = os.time()
  return M.report()
end

local function schedule_save()
  if not state.started or not can_run() or state.saving or state.restoring then
    return
  end
  if not state.debounce_timer then
    state.debounce_timer = uv.new_timer()
  end
  state.debounce_timer:stop()
  state.debounce_timer:start(
    state.config.save_debounce_ms,
    0,
    vim.schedule_wrap(function()
      if state.started and can_run() then
        save_now()
      end
    end)
  )
end

local function handle_restore_stats(stats)
  state.last_restore = stats
  if stats.recoveries > 0 then
    notify(
      string.format(
        "OSC 7577: %d recovered buffer(s) conflict with files that changed on disk; use :OSC7577Recoveries",
        stats.recoveries
      ),
      vim.log.levels.WARN
    )
  end
  if #stats.errors > 0 then
    notify(
      "OSC 7577: recovery completed with errors: " .. table.concat(stats.errors, "; "),
      vim.log.levels.WARN
    )
  end
end

local function restore_managed_session(id)
  state.ctx = session.context(state.config.state_dir, id)
  state.restored_session_id = id
  if state.config.snapshot_unsaved then
    state.restoring = true
    local ok, stats = pcall(buffers.restore, state.ctx)
    state.restoring = false
    if ok then
      handle_restore_stats(stats)
    else
      fail(stats)
    end
  end
end

local function on_session_load()
  if not can_run() or state.saving then
    return
  end
  local id = session.managed_id(vim.v.this_session, state.config.state_dir)
  if id then
    restore_managed_session(id)
  end
  if state.started then
    schedule_save()
  end
end

local function start()
  if state.started or not can_run() then
    return
  end
  local loaded_id = session.managed_id(vim.v.this_session, state.config.state_dir)
  local ctx = ensure_context()
  if loaded_id and ctx.id == loaded_id and state.restored_session_id ~= loaded_id then
    restore_managed_session(loaded_id)
  end
  state.started = true
  session.cleanup(state.config.state_dir, state.config.retention_days, ctx.id)
  save_now()
end

local function on_exit()
  if not can_run() then
    return
  end
  state.exiting = true
  stop_timers()

  local reason_ok, exit_reason = pcall(function()
    return vim.v.exitreason
  end)
  if not reason_ok then
    exit_reason = nil
  end
  local intentional = vim.v.dying == 0 and exit_reason ~= "restart"
  if intentional then
    local delivered = false
    if state.ctx then
      delivered = send_clear()
    end
    if delivered then
      session.delete(state.ctx)
      state.ctx = nil
    end
    state.disabled = true
  elseif vim.v.dying == 0 then
    save_now()
  end
end

local function register_lifecycle()
  if state.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
  end
  stop_timers()
  state.augroup = vim.api.nvim_create_augroup("osc7577.nvim", { clear = true })
  local group = state.augroup

  vim.api.nvim_create_autocmd("VimEnter", { group = group, callback = start })
  vim.api.nvim_create_autocmd("SessionLoadPost", { group = group, callback = on_session_load })
  vim.api.nvim_create_autocmd("VimSuspend", {
    group = group,
    callback = function()
      if state.started then
        save_now()
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimResume", {
    group = group,
    callback = function()
      if state.started then
        save_now()
      end
    end,
  })
  vim.api.nvim_create_autocmd("ShellCmdPost", {
    group = group,
    callback = function()
      if state.started then
        M.report()
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = on_exit })

  vim.api.nvim_create_autocmd({
    "BufAdd",
    "BufDelete",
    "BufReadPost",
    "BufWritePost",
    "DirChanged",
    "TabNew",
    "TabClosed",
    "WinNew",
    "WinClosed",
    "TextChanged",
    "TextChangedI",
  }, {
    group = group,
    callback = function()
      if not state.restoring then
        schedule_save()
      end
    end,
  })

  if state.config.save_interval_ms > 0 then
    state.interval_timer = uv.new_timer()
    state.interval_timer:start(
      state.config.save_interval_ms,
      state.config.save_interval_ms,
      vim.schedule_wrap(function()
        if state.started and can_run() then
          save_now()
        end
      end)
    )
  end
end

local function stop_lifecycle()
  state.started = false
  stop_timers()
  if state.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
    state.augroup = nil
  end
end

local function status_lines()
  local status = M.status()
  local lines = {
    "Active: " .. tostring(status.active),
    "Started: " .. tostring(status.started),
    "Session: " .. (status.session_path or "none"),
    "Unsaved snapshots: " .. status.snapshot_count,
    "Recovery buffers: " .. status.recovery_count,
  }
  if status.reason then
    lines[#lines + 1] = "Reason: " .. status.reason
  end
  if status.last_save then
    lines[#lines + 1] = "Last save: " .. os.date("%Y-%m-%d %H:%M:%S", status.last_save)
  end
  if status.last_report then
    lines[#lines + 1] = "Last report: " .. os.date("%Y-%m-%d %H:%M:%S", status.last_report)
  end
  if status.last_error then
    lines[#lines + 1] = "Last error: " .. status.last_error
  end
  return table.concat(lines, "\n")
end

local function create_commands()
  if state.commands_created then
    return
  end
  state.commands_created = true
  local command = vim.api.nvim_create_user_command
  command("OSC7577Save", function()
    M.save()
  end, { desc = "Save and report the OSC 7577 session" })
  command("OSC7577Status", function()
    vim.notify(status_lines(), vim.log.levels.INFO, { title = "osc7577.nvim" })
  end, { desc = "Show OSC 7577 session status" })
  command("OSC7577Disable", function()
    M.disable()
  end, { desc = "Clear and disable the OSC 7577 session" })
  command("OSC7577Enable", function()
    M.enable()
  end, { desc = "Enable the OSC 7577 session" })
  command("OSC7577Cleanup", function()
    local removed, err = M.cleanup()
    if removed then
      vim.notify(
        string.format(
          "OSC 7577: removed %d expired session(s)%s",
          removed,
          err and ("; " .. err) or ""
        ),
        vim.log.levels.INFO,
        { title = "osc7577.nvim" }
      )
    else
      fail(err)
    end
  end, { desc = "Remove expired OSC 7577 sessions" })
  command("OSC7577Recoveries", function()
    buffers.show_recoveries()
  end, { desc = "List OSC 7577 recovery buffers" })
end

function M.setup(opts)
  local was_active = can_run()
  local old_dir = state.config and state.config.state_dir
  stop_lifecycle()
  state.config = vim.tbl_deep_extend("force", defaults(), opts or {})
  state.config.state_dir = util.normalize(state.config.state_dir)
  if old_dir and old_dir ~= state.config.state_dir then
    state.ctx = nil
    state.restored_session_id = nil
  end
  state.did_setup = true
  state.exiting = false
  state.disabled = not state.config.enabled
  state.active = false
  create_commands()

  if was_active and not state.config.enabled then
    if state.ctx then
      if state.token then
        send_clear()
      end
      session.delete(state.ctx)
      state.ctx = nil
    end
    state.restored_session_id = nil
  end

  if not state.config.enabled then
    state.unsupported = "disabled by configuration"
    return M
  end
  if not capture_token() then
    return M
  end

  state.active = true
  state.disabled = false
  register_lifecycle()
  if vim.v.vim_did_enter == 1 then
    start()
  end
  return M
end

function M.save()
  if not state.did_setup then
    M.setup()
  end
  if not can_run() then
    return fail(state.unsupported or "OSC 7577 is disabled")
  end
  ensure_context()
  state.started = true
  return save_now()
end

function M.disable()
  if not state.did_setup then
    M.setup()
  end
  stop_lifecycle()
  if state.ctx and state.token then
    send_clear()
  end
  if state.ctx then
    session.delete(state.ctx)
  end
  state.ctx = nil
  state.restored_session_id = nil
  state.disabled = true
  state.active = false
  return true
end

function M.enable()
  if not state.did_setup then
    M.setup()
  end
  state.config.enabled = true
  if not capture_token() then
    return fail(state.unsupported)
  end
  state.disabled = false
  state.active = true
  register_lifecycle()
  start()
  return true
end

function M.cleanup()
  if not state.did_setup then
    M.setup()
  end
  return session.cleanup(
    state.config.state_dir,
    state.config.retention_days,
    state.ctx and state.ctx.id or nil
  )
end

function M.status()
  return {
    active = can_run(),
    started = state.started,
    reason = can_run() and nil or (state.disabled and "disabled" or state.unsupported),
    session_path = state.ctx and state.ctx.session_path or nil,
    snapshot_count = state.snapshot_stats.count or 0,
    snapshot_bytes = state.snapshot_stats.bytes or 0,
    recovery_count = #buffers.recoveries(),
    last_save = state.last_save,
    last_report = state.last_report,
    last_error = state.last_error,
    last_restore = state.last_restore,
  }
end

function M._bootstrap()
  create_commands()
  if not state.did_setup and vim.g.osc7577_auto_setup ~= false then
    M.setup()
  end
end

return M
