return {
  dir = vim.fn.stdpath('config') .. '/lua/arnie-bot',
  name = 'arnie-bot',
  keys = {
    { '<leader>ca', mode = { 'n', 'v' }, desc = 'Ask Arnie Bot (fresh)' },
    { '<leader>cA', mode = { 'n', 'v' }, desc = 'Ask Arnie Bot (continue session)' },
    { '<leader>ct', mode = 'n', desc = 'Open Arnie Bot terminal' },
    { '<leader>cd', mode = 'n', desc = 'Dismiss Arnie Bot response' },
    { '<leader>cx', mode = 'n', desc = 'Cancel Arnie Bot request' },
  },
  opts = {
    keymaps = {
      ask = '<leader>ca',
      dismiss = '<leader>cd',
      cancel = '<leader>cx',
    },
    -- Model: nil (default), 'haiku' (fastest), 'sonnet' (balanced), 'opus' (most capable)
    model = 'sonnet',
    -- Set to true to allow Arnie Bot to use tools (Edit, Read, Write, Bash, etc.)
    -- WARNING: Tools make responses slower as Arnie Bot may read/analyze files
    allow_tools = true,
    -- Optionally restrict to specific tools (only used if allow_tools is true)
    -- Set to nil to allow all tools, or specify a list:
    -- allowed_tools = { 'Edit', 'Read', 'Write' },
    allowed_tools = nil,
    -- Skip all permission checks (use only in trusted directories!)
    skip_permissions = true,
  },
  config = function(_, opts)
    require('arnie-bot').setup(opts)
  end,
}
