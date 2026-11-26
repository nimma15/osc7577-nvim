local util = require("osc7577.util")
local uv = vim.uv or vim.loop

local M = {}

local function valid_id(id)
  return type(id) == "string" and id:match("^%x+$") ~= nil and #id == 32
end

function M.context(state_dir, id)
  assert(valid_id(id), "invalid session ID")
  return {
    id = id,
    session_path = util.join(state_dir, id .. ".vim"),
    data_dir = util.join(state_dir, id .. ".d"),
    manifest_path = util.join(state_dir, id .. ".d", "manifest.json"),
  }
end

function M.new(state_dir)
  return M.context(state_dir, util.random_id(16))
end

function M.managed_id(path, state_dir)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  path = util.normalize(path)
  if vim.fs.dirname(path) ~= state_dir then
    return nil
  end
  local id = vim.fs.basename(path):match("^(%x+)%.vim$")
  if valid_id(id) then
    return id
  end
  return nil
end

function M.save(ctx, restore_terminals)
  local ok, err = util.ensure_dir(ctx.state_dir or vim.fs.dirname(ctx.session_path))
  if not ok then
    return nil, err
  end

  local tmp =
    util.join(vim.fs.dirname(ctx.session_path), ctx.id .. "." .. util.random_id(8) .. ".tmp.vim")
  local old_sessionoptions = vim.o.sessionoptions
  if not restore_terminals then
    local values = {}
    for value in old_sessionoptions:gmatch("[^,]+") do
      if value ~= "terminal" then
        values[#values + 1] = value
      end
    end
    vim.o.sessionoptions = table.concat(values, ",")
  end

  local saved, save_err = pcall(vim.cmd, "silent mksession! " .. vim.fn.fnameescape(tmp))
  vim.o.sessionoptions = old_sessionoptions
  if not saved then
    util.unlink(tmp)
    return nil, save_err
  end

  local chmod_ok, chmod_err = uv.fs_chmod(tmp, 384)
  if chmod_ok == nil then
    util.unlink(tmp)
    return nil, chmod_err
  end
  local renamed, rename_err = uv.fs_rename(tmp, ctx.session_path)
  if renamed == nil then
    util.unlink(tmp)
    return nil, rename_err
  end

  pcall(vim.cmd, "let v:this_session = " .. vim.fn.fnameescape(ctx.session_path))
  return true
end

function M.delete(ctx)
  local first_error
  local ok, err = util.unlink(ctx.session_path)
  if not ok then
    first_error = err
  end
  local removed, remove_result = pcall(vim.fn.delete, ctx.data_dir, "rf")
  if not removed or remove_result == -1 then
    first_error = first_error or ("could not remove " .. ctx.data_dir)
  end
  if first_error then
    return nil, first_error
  end
  return true
end

function M.cleanup(state_dir, retention_days, current_id)
  local ok, err = util.ensure_dir(state_dir)
  if not ok then
    return nil, err
  end

  local cutoff = os.time() - math.floor(retention_days * 86400)
  local removed, errors = 0, {}
  local handle, scan_err = uv.fs_scandir(state_dir)
  if not handle then
    return nil, scan_err
  end
  local candidates = {}

  while true do
    local name, kind = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if kind == "file" and (name:match("%.tmp$") or name:match("%.tmp%.vim$")) then
      local path = util.join(state_dir, name)
      local stat = uv.fs_stat(path)
      if stat and stat.mtime.sec < cutoff then
        util.unlink(path)
      end
    end
    local id
    if kind == "file" then
      id = name:match("^(%x+)%.vim$")
    elseif kind == "directory" then
      id = name:match("^(%x+)%.d$")
    end
    if valid_id(id) and id ~= current_id then
      candidates[id] = true
    end
  end

  for id in pairs(candidates) do
    local ctx = M.context(state_dir, id)
    local newest = 0
    for _, marker in ipairs({ ctx.session_path, ctx.data_dir }) do
      local stat = uv.fs_stat(marker)
      if stat then
        newest = math.max(newest, stat.mtime.sec)
      end
    end
    if newest > 0 and newest < cutoff then
      local deleted, delete_err = M.delete(ctx)
      if deleted then
        removed = removed + 1
      else
        errors[#errors + 1] = delete_err
      end
    end
  end
  return removed, #errors > 0 and table.concat(errors, "; ") or nil
end

return M
