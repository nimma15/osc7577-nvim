local uv = vim.uv or vim.loop

local M = {}

function M.write(sequence)
  local offset = 0
  while offset < #sequence do
    local written, write_err = uv.fs_write(1, sequence:sub(offset + 1), -1)
    if not written then
      return nil, write_err
    end
    offset = offset + written
  end
  return true
end

return M
