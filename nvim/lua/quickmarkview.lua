local M = {}

M.app = "QuickMarkview"

function M.open()
  local path = vim.fn.expand("%:p")
  if path == "" then
    vim.notify("QuickMarkview: current buffer has no file", vim.log.levels.ERROR)
    return
  end

  local line = vim.api.nvim_win_get_cursor(0)[1]
  local pane = vim.env.WEZTERM_PANE
  if not pane or pane == "" then
    vim.notify("QuickMarkview: WEZTERM_PANE is not set", vim.log.levels.ERROR)
    return
  end

  -- vim.system receives argv directly; the path never passes through a shell.
  vim.system({
    "open", "-n", "-a", M.app, "--args",
    "--line", tostring(line),
    "--pane", tostring(pane),
    path,
  }, { text = true }, function(result)
    if result.code ~= 0 then
      vim.schedule(function()
        vim.notify("QuickMarkview: " .. (result.stderr or "could not launch app"), vim.log.levels.ERROR)
      end)
    end
  end)
end

return M
