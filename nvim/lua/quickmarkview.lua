local M = {}

M.app = "QuickMarkview"
M.resident = false

local function source_position()
  local table_wrap = package.loaded["markdown-table-wrap"]
  local state = table_wrap and table_wrap.get_state(0)
  if state and state.source_path then
    return state.source_path, state.cursor.source_lnum
  end
  return vim.fn.expand("%:p"), vim.api.nvim_win_get_cursor(0)[1]
end

function M.open()
  local path, line = source_position()
  if path == "" then
    vim.notify("QuickMarkview: current buffer has no file", vim.log.levels.ERROR)
    return
  end

  local pane = vim.env.WEZTERM_PANE
  if not pane or pane == "" then
    vim.notify("QuickMarkview: WEZTERM_PANE is not set", vim.log.levels.ERROR)
    return
  end

  local arguments
  if M.resident then
    local request = "quickmarkview://open?path=" .. vim.uri_encode(path, "rfc3986")
      .. "&line=" .. tostring(line) .. "&pane=" .. tostring(pane)
    arguments = { "open", "-a", M.app, request, "--args", "--resident" }
  else
    arguments = {
      "open", "-n", "-a", M.app, "--args",
      "--line", tostring(line),
      "--pane", tostring(pane),
      path,
    }
  end

  -- vim.system receives argv directly; the path never passes through a shell.
  vim.system(arguments, { text = true }, function(result)
    if result.code ~= 0 then
      vim.schedule(function()
        vim.notify("QuickMarkview: " .. (result.stderr or "could not launch app"), vim.log.levels.ERROR)
      end)
    end
  end)
end

return M
