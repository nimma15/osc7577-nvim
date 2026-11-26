local protocol = require("osc7577.protocol")
local util = require("osc7577.util")
local uv = vim.uv or vim.loop

local M = {}

local function is_uri(name)
  return name:match("^%a[%w+.-]*://") ~= nil
end

local function full_name(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" or is_uri(name) then
    return nil
  end
  return util.normalize(name)
end

local function contents(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  return table.concat(lines, "\n")
end

local function find_file_buffer(path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == "" then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" and not is_uri(name) and util.normalize(name) == path then
        return buf
      end
    end
  end
  return nil
end

local function snapshot_name(entry)
  return "buffers/" .. entry.key .. "-" .. util.random_id(8) .. ".snapshot"
end

function M.save(ctx, opts)
  local ok, err = util.ensure_dir(ctx.data_dir)
  if not ok then
    return nil, err
  end
  ok, err = util.ensure_dir(util.join(ctx.data_dir, "buffers"))
  if not ok then
    return nil, err
  end

  local entries, skipped = {}, {}
  local total, unnamed_ordinal = 0, 0
  local buffers = vim.api.nvim_list_bufs()
  table.sort(buffers)

  for _, buf in ipairs(buffers) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) then
      local buftype = vim.bo[buf].buftype
      local path = full_name(buf)
      local eligible = buftype == "" and (path ~= nil or vim.api.nvim_buf_get_name(buf) == "")
      if eligible and path and not protocol.valid_text(path) then
        eligible = false
      end

      if eligible then
        local modified = vim.bo[buf].modified
        local unnamed = path == nil
        local data = (modified or unnamed) and contents(buf) or nil
        if unnamed and (modified or data ~= "") then
          unnamed_ordinal = unnamed_ordinal + 1
        end
        local wanted = modified or (unnamed and data ~= "")

        if wanted and (vim.bo[buf].binary or data:find("\0", 1, true)) then
          skipped[#skipped + 1] = string.format("buffer %d is binary", buf)
        elseif wanted then
          if #data > opts.max_buffer_bytes then
            skipped[#skipped + 1] = string.format("buffer %d exceeds max_buffer_bytes", buf)
          elseif total + #data > opts.max_total_bytes then
            skipped[#skipped + 1] = string.format("buffer %d exceeds max_total_bytes", buf)
          else
            local identity = unnamed and ("unnamed:" .. unnamed_ordinal) or ("file:" .. path)
            local entry = {
              key = vim.fn.sha256(identity):sub(1, 32),
              name = unnamed and "" or path,
              unnamed = unnamed,
              ordinal = unnamed and unnamed_ordinal or nil,
              filetype = vim.bo[buf].filetype,
              options = {
                fileformat = vim.bo[buf].fileformat,
                endofline = vim.bo[buf].endofline,
                bomb = vim.bo[buf].bomb,
              },
            }
            if not unnamed then
              entry.disk = util.disk_signature(path)
            end
            entry.file = snapshot_name(entry)
            local written, write_err = util.write_atomic(util.join(ctx.data_dir, entry.file), data)
            if written then
              entries[#entries + 1] = entry
              total = total + #data
            else
              skipped[#skipped + 1] = string.format("buffer %d: %s", buf, tostring(write_err))
            end
          end
        end
      end
    end
  end

  local manifest = {
    version = 1,
    session_id = ctx.id,
    saved_at = os.time(),
    buffers = entries,
  }
  local encode_ok, encoded = pcall(vim.json.encode, manifest)
  if not encode_ok then
    return nil, encoded
  end
  local written, write_err = util.write_atomic(ctx.manifest_path, encoded)
  if not written then
    return nil, write_err
  end

  local keep = {}
  for _, entry in ipairs(entries) do
    keep[entry.file:match("^buffers/(.+)$")] = true
  end
  local buffer_dir = util.join(ctx.data_dir, "buffers")
  local handle = uv.fs_scandir(buffer_dir)
  if handle then
    while true do
      local name, kind = uv.fs_scandir_next(handle)
      if not name then
        break
      end
      if kind == "file" and name:match("%.snapshot$") and not keep[name] then
        util.unlink(util.join(buffer_dir, name))
      end
    end
  end

  return true, {
    count = #entries,
    bytes = total,
    skipped = skipped,
  }
end

local function set_buffer_text(buf, entry, data)
  local modifiable = vim.bo[buf].modifiable
  if not modifiable then
    vim.bo[buf].modifiable = true
  end
  local ok, err =
    pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, vim.split(data, "\n", { plain = true }))
  if not modifiable then
    vim.bo[buf].modifiable = false
  end
  if not ok then
    return nil, err
  end

  if entry.filetype and entry.filetype ~= "" and vim.bo[buf].filetype == "" then
    pcall(function()
      vim.bo[buf].filetype = entry.filetype
    end)
  end
  if type(entry.options) == "table" and vim.bo[buf].buftype == "" then
    pcall(function()
      if entry.options.fileformat then
        vim.bo[buf].fileformat = entry.options.fileformat
      end
      if entry.options.endofline ~= nil then
        vim.bo[buf].endofline = entry.options.endofline
      end
      if entry.options.bomb ~= nil then
        vim.bo[buf].bomb = entry.options.bomb
      end
    end)
  end
  vim.bo[buf].modified = true
  vim.b[buf].osc7577_restored = true
  return true
end

local function recovery_buffer(ctx, entry, data)
  local buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_name(
    buf,
    string.format("osc7577-recovery://%s/%d-%s", ctx.id, buf, entry.key)
  )
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.b[buf].osc7577_recovery_for = entry.unnamed and ("unnamed buffer " .. tostring(entry.ordinal))
    or entry.name
  vim.b[buf].osc7577_recovery_session = ctx.id
  local ok, err = set_buffer_text(buf, entry, data)
  if not ok then
    return nil, err
  end
  return buf
end

local function load_manifest(ctx)
  local encoded, read_err = util.read_file(ctx.manifest_path)
  if not encoded then
    return nil, read_err
  end
  local ok, decoded = pcall(vim.json.decode, encoded)
  if not ok or type(decoded) ~= "table" then
    return nil, "invalid recovery manifest"
  end
  if decoded.version ~= 1 or decoded.session_id ~= ctx.id or type(decoded.buffers) ~= "table" then
    return nil, "recovery manifest does not belong to this session"
  end
  return decoded
end

function M.restore(ctx)
  if not uv.fs_stat(ctx.manifest_path) then
    return { applied = 0, recoveries = 0, errors = {} }
  end
  local manifest, manifest_err = load_manifest(ctx)
  if not manifest then
    return { applied = 0, recoveries = 0, errors = { manifest_err } }
  end

  local unnamed_candidates = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if
      vim.api.nvim_buf_is_valid(buf)
      and vim.api.nvim_buf_is_loaded(buf)
      and vim.bo[buf].buftype == ""
      and vim.api.nvim_buf_get_name(buf) == ""
      and contents(buf) == ""
    then
      unnamed_candidates[#unnamed_candidates + 1] = buf
    end
  end
  table.sort(unnamed_candidates)

  local stats = { applied = 0, recoveries = 0, errors = {} }
  local used = {}
  for _, entry in ipairs(manifest.buffers) do
    if
      type(entry) == "table"
      and type(entry.file) == "string"
      and entry.file:match("^buffers/[%x]+%-[%x]+%.snapshot$")
      and type(entry.key) == "string"
    then
      local data, read_err = util.read_file(util.join(ctx.data_dir, entry.file))
      if not data then
        stats.errors[#stats.errors + 1] = read_err
      else
        if entry.unnamed then
          local ordinal = tonumber(entry.ordinal) or 1
          local buf = unnamed_candidates[ordinal]
          if buf and used[buf] then
            buf = nil
          end
          if not buf then
            buf = vim.api.nvim_create_buf(true, false)
          end
          local ok, err = set_buffer_text(buf, entry, data)
          if ok then
            used[buf] = true
            stats.applied = stats.applied + 1
          else
            stats.errors[#stats.errors + 1] = tostring(err)
          end
        elseif type(entry.name) == "string" and entry.name ~= "" then
          local buf = find_file_buffer(entry.name)
          if not buf then
            local ok, added = pcall(vim.fn.bufadd, entry.name)
            if ok and added > 0 then
              buf = added
              pcall(vim.fn.bufload, buf)
            end
          end
          if not buf then
            stats.errors[#stats.errors + 1] = "could not create buffer for " .. entry.name
          elseif util.same_disk_signature(entry.disk, util.disk_signature(entry.name)) then
            local ok, err = set_buffer_text(buf, entry, data)
            if ok then
              stats.applied = stats.applied + 1
            else
              stats.errors[#stats.errors + 1] = tostring(err)
            end
          else
            local recovered, recovery_err = recovery_buffer(ctx, entry, data)
            if recovered then
              stats.recoveries = stats.recoveries + 1
            else
              stats.errors[#stats.errors + 1] = tostring(recovery_err)
            end
          end
        end
      end
    else
      stats.errors[#stats.errors + 1] = "invalid recovery manifest entry"
    end
  end
  return stats
end

function M.recoveries()
  local found = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      local ok, origin = pcall(function()
        return vim.b[buf].osc7577_recovery_for
      end)
      if ok and type(origin) == "string" then
        found[#found + 1] = { bufnr = buf, text = "Recovered unsaved version of " .. origin }
      end
    end
  end
  return found
end

function M.show_recoveries()
  local found = M.recoveries()
  if #found == 0 then
    vim.notify("No OSC 7577 recovery buffers", vim.log.levels.INFO)
    return
  end
  vim.fn.setqflist({}, " ", { title = "OSC 7577 Recoveries", items = found })
  vim.cmd("copen")
end

return M
