local uv = vim.uv or vim.loop

local M = {}

function M.join(...)
  return table.concat({ ... }, "/")
end

function M.normalize(path)
  path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  if path ~= "/" then
    path = path:gsub("/+$", "")
  end
  return path
end

function M.random_id(bytes)
  bytes = bytes or 16
  local ok, random = pcall(uv.random, bytes)
  if not ok or type(random) ~= "string" or #random ~= bytes then
    local seed = table.concat({
      tostring(vim.fn.getpid()),
      tostring(uv.hrtime()),
      tostring(os.time()),
      tostring(math.random()),
    }, ":")
    return (vim.fn.sha256(seed):sub(1, bytes * 2))
  end
  return (random:gsub(".", function(char)
    return string.format("%02x", char:byte())
  end))
end

local function basename(name)
  name = tostring(name or "")
  return (name:gsub("[/\\]+$", ""):match("([^/\\]+)$")) or name
end

local parent_name = { ppid = nil, name = false }

local function process_name(pid)
  if pid == parent_name.ppid then
    return parent_name.name
  end
  local name = false
  local comm = io.open(("/proc/%d/comm"):format(pid))
  if comm then
    local line = comm:read("*l") or ""
    comm:close()
    if line ~= "" then
      name = line
    end
  else
    local ok, output = pcall(vim.fn.system, { "ps", "-o", "comm=", "-p", tostring(pid) })
    if ok and vim.v.shell_error == 0 and type(output) == "string" then
      local line = output:gsub("%s+$", "")
      if line ~= "" then
        name = basename(line)
      end
    end
  end
  if pid == uv.os_getppid() then
    parent_name.ppid = pid
    parent_name.name = name
  end
  return name
end

function M.owning_pid(ppid, parent)
  ppid = ppid or uv.os_getppid()
  if ppid and ppid > 1 then
    if type(parent) == "string" then
      parent = basename(parent)
    else
      parent = parent or process_name(ppid)
    end
    if parent == "nvim" then
      return ppid
    end
  end
  return vim.fn.getpid()
end

function M.ensure_dir(path)
  local ok, err = pcall(vim.fn.mkdir, path, "p", 448)
  if not ok then
    return nil, err
  end
  local chmod_ok, chmod_err = uv.fs_chmod(path, 448)
  if chmod_ok == nil then
    return nil, chmod_err
  end
  return true
end

function M.unlink(path)
  local ok, err = uv.fs_unlink(path)
  if ok == nil and err and not err:match("^ENOENT") then
    return nil, err
  end
  return true
end

function M.read_file(path)
  local fd, open_err = uv.fs_open(path, "r", 384)
  if not fd then
    return nil, open_err
  end
  local stat, stat_err = uv.fs_fstat(fd)
  if not stat then
    uv.fs_close(fd)
    return nil, stat_err
  end
  local data, read_err = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  if data == nil then
    return nil, read_err
  end
  return data
end

function M.write_atomic(path, contents)
  local dir = vim.fs.dirname(path)
  local ok, err = M.ensure_dir(dir)
  if not ok then
    return nil, err
  end

  local tmp = string.format("%s.%s.tmp", path, M.random_id(8))
  local fd, open_err = uv.fs_open(tmp, "w", 384)
  if not fd then
    return nil, open_err
  end

  local offset = 0
  while offset < #contents do
    local written, write_err = uv.fs_write(fd, contents:sub(offset + 1), -1)
    if not written then
      uv.fs_close(fd)
      M.unlink(tmp)
      return nil, write_err
    end
    offset = offset + written
  end

  uv.fs_fsync(fd)
  uv.fs_chmod(tmp, 384)
  uv.fs_close(fd)

  local renamed, rename_err = uv.fs_rename(tmp, path)
  if renamed == nil then
    M.unlink(tmp)
    return nil, rename_err
  end
  return true
end

function M.disk_signature(path)
  local stat = uv.fs_stat(path)
  if not stat then
    return { exists = false }
  end
  return {
    exists = true,
    mtime_sec = stat.mtime.sec,
    mtime_nsec = stat.mtime.nsec or 0,
    size = stat.size,
  }
end

function M.same_disk_signature(left, right)
  if type(left) ~= "table" or type(right) ~= "table" then
    return false
  end
  if left.exists == false or right.exists == false then
    return left.exists == right.exists
  end
  return left.mtime_sec == right.mtime_sec
    and (left.mtime_nsec or 0) == (right.mtime_nsec or 0)
    and left.size == right.size
end

return M
