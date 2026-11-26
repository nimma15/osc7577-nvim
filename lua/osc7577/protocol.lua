local M = {}

M.MAX_SEQUENCE_BYTES = 2048
M.MAX_ARGV_ELEMENTS = 64

function M.valid_token(token)
  return type(token) == "string"
    and #token >= 22
    and #token <= 64
    and token:match("^[A-Za-z0-9_-]+$") ~= nil
end

function M.valid_text(text)
  if type(text) ~= "string" then
    return false
  end

  local i = 1
  while i <= #text do
    local a = text:byte(i)
    if a <= 0x1f or a == 0x7f then
      return false
    elseif a <= 0x7f then
      i = i + 1
    elseif a >= 0xc2 and a <= 0xdf then
      local b = text:byte(i + 1)
      if not b or b < 0x80 or b > 0xbf then
        return false
      end
      if a == 0xc2 and b >= 0x80 and b <= 0x9f then
        return false
      end
      i = i + 2
    elseif a >= 0xe0 and a <= 0xef then
      local b, c = text:byte(i + 1), text:byte(i + 2)
      if not b or not c or c < 0x80 or c > 0xbf then
        return false
      end
      if a == 0xe0 then
        if b < 0xa0 or b > 0xbf then
          return false
        end
      elseif a == 0xed then
        if b < 0x80 or b > 0x9f then
          return false
        end
      elseif b < 0x80 or b > 0xbf then
        return false
      end
      i = i + 3
    elseif a >= 0xf0 and a <= 0xf4 then
      local b, c, d = text:byte(i + 1), text:byte(i + 2), text:byte(i + 3)
      if not b or not c or not d or c < 0x80 or c > 0xbf or d < 0x80 or d > 0xbf then
        return false
      end
      if a == 0xf0 then
        if b < 0x90 or b > 0xbf then
          return false
        end
      elseif a == 0xf4 then
        if b < 0x80 or b > 0x8f then
          return false
        end
      elseif b < 0x80 or b > 0xbf then
        return false
      end
      i = i + 4
    else
      return false
    end
  end
  return true
end

local function positive_integer(value, name)
  if type(value) ~= "number" or value < 1 or value ~= math.floor(value) then
    return nil, name .. " must be a positive integer"
  end
  return string.format("%d", value)
end

local function validate_executable(executable)
  if executable == "" then
    return nil, "argv[0] cannot be empty"
  end
  if executable:sub(1, 1) == "/" then
    return true
  end
  if executable:sub(1, 1) == "-" then
    return nil, "a bare argv[0] cannot start with '-'"
  end
  if executable:find("/", 1, true) then
    return nil, "argv[0] must be a bare command name or an absolute path"
  end
  return true
end

local function build(opts, clear)
  if not M.valid_token(opts.token) then
    return nil, "invalid OSC7577 token"
  end
  local pid, pid_err = positive_integer(opts.pid, "pid")
  if not pid then
    return nil, pid_err
  end
  local time, time_err = positive_integer(opts.time, "time")
  if not time then
    return nil, time_err
  end

  local fields = { "pid=" .. pid, "time=" .. time }
  if clear then
    fields[#fields + 1] = "clear=1"
  else
    if type(opts.argv) ~= "table" or #opts.argv < 1 then
      return nil, "argv must contain at least one element"
    end
    if #opts.argv > M.MAX_ARGV_ELEMENTS then
      return nil, "argv exceeds 64 elements"
    end

    local encoded = {}
    for index, argument in ipairs(opts.argv) do
      if not M.valid_text(argument) then
        return nil, "argv contains invalid UTF-8 or a prohibited control character"
      end
      if index == 1 then
        local ok, err = validate_executable(argument)
        if not ok then
          return nil, err
        end
      end
      encoded[index] = vim.base64.encode(argument)
    end
    fields[#fields + 1] = "argv=" .. table.concat(encoded, ",")

    if opts.cwd ~= nil then
      if not M.valid_text(opts.cwd) or opts.cwd:sub(1, 1) ~= "/" then
        return nil, "cwd must be an absolute, valid UTF-8 path without control characters"
      end
      fields[#fields + 1] = "cwd=" .. vim.base64.encode(opts.cwd)
    end
  end

  local body = table.concat(fields, ":")
  local mac = vim.fn.sha256(body .. ":" .. opts.token)
  local sequence = "\27]7577;" .. body .. ":mac=" .. mac .. "\27\\"
  if #sequence > M.MAX_SEQUENCE_BYTES then
    return nil, "OSC 7577 report exceeds 2048 bytes"
  end

  return {
    body = body,
    mac = mac,
    sequence = sequence,
  }
end

function M.report(opts)
  if opts.clear then
    return nil, "a report cannot contain both argv and clear"
  end
  return build(opts, false)
end

function M.clear(opts)
  if opts.argv ~= nil then
    return nil, "a clear report cannot contain argv"
  end
  return build(opts, true)
end

return M
