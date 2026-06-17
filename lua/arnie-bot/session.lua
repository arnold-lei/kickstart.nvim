local M = {}

M.session_id = nil

-- Encode a filesystem path the way Claude Code does:
-- replaces / and . with -
local function encode_path(path)
  return (path:gsub('[/.]', '-'))
end

-- Directory where Claude Code stores sessions for the current project
local function get_sessions_dir()
  local home = vim.fn.expand '~'
  return home .. '/.claude/projects/' .. encode_path(vim.fn.getcwd())
end

-- File used to persist the active session ID across Neovim restarts
local function persistence_path()
  local data_dir = vim.fn.stdpath 'data' .. '/arnie-bot'
  vim.fn.mkdir(data_dir, 'p')
  return data_dir .. '/' .. encode_path(vim.fn.getcwd())
end

-- Read only enough of a JSONL file to get the first user message + metadata
local function parse_session(filepath)
  local file = io.open(filepath, 'r')
  if not file then
    return nil
  end

  local result = {}
  local lines_read = 0

  for line in file:lines() do
    lines_read = lines_read + 1
    if lines_read > 30 then
      break
    end

    local ok, obj = pcall(vim.fn.json_decode, line)
    if ok and obj and obj.type == 'user' and obj.message then
      local content = obj.message.content
      if type(content) == 'string' and content ~= '' then
        result.first_message = content
        result.timestamp = obj.timestamp
        result.git_branch = obj.gitBranch
        break
      end
    end
  end

  file:close()

  if not result.first_message then
    return nil
  end
  return result
end

-- Format an ISO timestamp for compact display
local function format_time(ts)
  if not ts then
    return ''
  end
  local year, month, day, hour, min = ts:match '^(%d+)-(%d+)-(%d+)T(%d+):(%d+)'
  if not year then
    return ''
  end

  local now = os.date '*t'
  local months = { 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec' }
  local m, d = tonumber(month), tonumber(day)

  if tonumber(year) == now.year and m == now.month and d == now.day then
    return 'today ' .. hour .. ':' .. min
  elseif tonumber(year) == now.year and m == now.month and d == now.day - 1 then
    return 'yesterday'
  else
    return months[m] .. ' ' .. d
  end
end

-- List all sessions for the current project, sorted newest first
function M.list_sessions()
  local dir = get_sessions_dir()
  if vim.fn.isdirectory(dir) == 0 then
    return {}
  end

  local sessions = {}
  local handle = vim.loop.fs_scandir(dir)
  if not handle then
    return {}
  end

  while true do
    local name, ftype = vim.loop.fs_scandir_next(handle)
    if not name then
      break
    end

    local uuid = name:match '^([0-9a-f%-]+)%.jsonl$'
    if ftype == 'file' and uuid then
      local filepath = dir .. '/' .. name
      local stat = vim.loop.fs_stat(filepath)
      local meta = parse_session(filepath)
      if meta then
        table.insert(sessions, {
          id = uuid,
          filepath = filepath,
          mtime = stat and stat.mtime.sec or 0,
          first_message = meta.first_message,
          timestamp = meta.timestamp,
          git_branch = meta.git_branch,
          is_active = uuid == M.session_id,
        })
      end
    end
  end

  table.sort(sessions, function(a, b)
    return a.mtime > b.mtime
  end)

  return sessions
end

-- Open a Telescope picker to browse and select a session
function M.pick_session(on_select)
  local sessions = M.list_sessions()
  if #sessions == 0 then
    vim.notify('Arnie Bot: No sessions found for this project', vim.log.levels.WARN)
    return
  end

  local pickers = require 'telescope.pickers'
  local finders = require 'telescope.finders'
  local conf = require('telescope.config').values
  local actions = require 'telescope.actions'
  local action_state = require 'telescope.actions.state'
  local previewers = require 'telescope.previewers'

  pickers
    .new({}, {
      prompt_title = 'Claude Sessions',
      finder = finders.new_table {
        results = sessions,
        entry_maker = function(s)
          local active = s.is_active and '● ' or '○ '
          local time = format_time(s.timestamp)
          local branch = s.git_branch and ('[' .. s.git_branch .. '] ') or ''
          local preview = s.first_message:gsub('\n', ' '):sub(1, 55)
          local display = string.format(
            '%s%s  %-16s  %s%s',
            active,
            s.id:sub(1, 8),
            time,
            branch,
            preview
          )
          return {
            value = s,
            display = display,
            ordinal = s.first_message .. ' ' .. (s.git_branch or '') .. ' ' .. s.id,
          }
        end,
      },
      sorter = conf.generic_sorter {},
      previewer = previewers.new_buffer_previewer {
        title = 'Session',
        define_preview = function(self, entry)
          local s = entry.value
          local lines = {
            'ID:       ' .. s.id,
            'Branch:   ' .. (s.git_branch or 'unknown'),
            'Started:  ' .. (s.timestamp or ''),
            'Active:   ' .. (s.is_active and 'yes (current)' or 'no'),
            '',
            '── First message ──────────────────────────────',
            '',
          }
          for _, l in ipairs(vim.split(s.first_message, '\n')) do
            table.insert(lines, l)
          end
          vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
        end,
      },
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          local selection = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if selection then
            on_select(selection.value)
          end
        end)
        return true
      end,
    })
    :find()
end

-- Switch to a session by UUID
function M.restore(uuid)
  M.session_id = uuid
  M.persist()
  vim.notify('Arnie Bot: session ' .. uuid:sub(1, 8) .. '…', vim.log.levels.INFO)
end

-- Write the active session ID to disk so it survives Neovim restarts
function M.persist()
  if not M.session_id then
    return
  end
  local path = persistence_path()
  local file = io.open(path, 'w')
  if file then
    file:write(M.session_id)
    file:close()
  end
end

-- Read back a previously persisted session ID on startup
function M.load_saved()
  local path = persistence_path()
  local file = io.open(path, 'r')
  if not file then
    return
  end
  local id = file:read '*l'
  file:close()
  if id and id:match '^[0-9a-f%-]+$' then
    M.session_id = id
    vim.notify('Arnie Bot: restored session ' .. id:sub(1, 8) .. '…', vim.log.levels.INFO)
  end
end

function M.new_session()
  M.session_id = nil
  vim.notify('Arnie Bot: new session started', vim.log.levels.INFO)
end

function M.debug()
  if M.session_id then
    vim.notify('Arnie Bot session: ' .. M.session_id, vim.log.levels.INFO)
  else
    vim.notify('Arnie Bot: no active session', vim.log.levels.WARN)
  end
end

return M
