local skills = require 'arnie-bot.skills'
local session = require 'arnie-bot.session'

local M = {}

M.config = {
  keymaps = {
    ask = '<leader>ca',
    ask_continue = '<leader>cA',
    terminal = '<leader>ct',
    dismiss = '<leader>cd',
    cancel = '<leader>cx',
    sessions = '<leader>cs',
  },
  -- Model to use (nil = default, 'haiku' = faster/cheaper, 'sonnet' = balanced, 'opus' = most capable)
  model = 'sonnet',
  -- Allow Arnie Bot to use tools (Edit, Read, Write, etc.)
  -- Set to true to enable file editing capabilities
  allow_tools = false,
  -- Specific tools to allow (only used if allow_tools is true)
  -- Example: { 'Edit', 'Read', 'Write' }
  allowed_tools = nil,
  -- Skip all permission checks (use only in trusted directories)
  skip_permissions = true,
}

-- Forward session management to session module
M.new_session = session.new_session
M.debug = session.debug

-- Namespace for virtual text
M.ns = vim.api.nvim_create_namespace 'arnie-bot'

-- Track current inline response state
M.current_response = nil

-- Get visually selected text and positions
function M.get_visual_selection()
  -- Exit visual mode to set '< and '> marks
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'nx', false)

  local start_pos = vim.fn.getpos "'<"
  local end_pos = vim.fn.getpos "'>"
  local start_line = start_pos[2]
  local end_line = end_pos[2]
  local start_col = start_pos[3]
  local end_col = end_pos[3]

  local lines = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)

  if #lines == 0 then
    return nil, nil
  end

  -- Handle partial line selection
  local text_lines = vim.deepcopy(lines)
  if #text_lines == 1 then
    text_lines[1] = string.sub(text_lines[1], start_col, end_col)
  else
    text_lines[1] = string.sub(text_lines[1], start_col)
    text_lines[#text_lines] = string.sub(text_lines[#text_lines], 1, end_col)
  end

  return table.concat(text_lines, '\n'),
    {
      start_line = start_line,
      end_line = end_line,
      start_col = start_col,
      end_col = end_col,
      buf = vim.api.nvim_get_current_buf(),
    }
end

-- Get context about the current file
function M.get_context()
  return {
    filetype = vim.bo.filetype,
    filename = vim.fn.expand '%:t',
    filepath = vim.fn.expand '%:p',
    cwd = vim.fn.getcwd(),
  }
end

-- Clear any existing inline response
function M.dismiss()
  if M.current_response then
    vim.api.nvim_buf_clear_namespace(M.current_response.buf, M.ns, 0, -1)
    M.current_response = nil
  end
end

-- Show inline virtual text wrapping the selection
function M.show_inline(buf, position, lines, is_loading)
  -- Clear previous virtual text in this namespace
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)

  local start_line = position.start_line or position
  local end_line = position.end_line or position

  -- Top border (above the selection)
  local top_virt = {}
  table.insert(top_virt, {
    { '┌─ Arnie Bot ', 'DiagnosticInfo' },
    { is_loading and '(loading...)' or '(done)', 'Comment' },
    { ' [<leader>cd dismiss, <leader>cx cancel]', 'DiagnosticHint' },
  })

  vim.api.nvim_buf_set_extmark(buf, M.ns, start_line - 1, 0, {
    virt_lines = top_virt,
    virt_lines_above = true,
  })

  -- Bottom content (below the selection)
  local bottom_virt = {}

  for _, text in ipairs(lines) do
    table.insert(bottom_virt, { { '│ ' .. text, 'Comment' } })
  end

  table.insert(bottom_virt, { { '└─', 'DiagnosticInfo' } })

  vim.api.nvim_buf_set_extmark(buf, M.ns, end_line - 1, 0, {
    virt_lines = bottom_virt,
    virt_lines_above = false,
  })
end

-- Spinner frames for loading animation
M.spinner_frames = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }

-- Stop the loading animation timer
function M.stop_spinner()
  if M.current_response and M.current_response.timer then
    M.current_response.timer:stop()
    M.current_response.timer:close()
    M.current_response.timer = nil
  end
end

-- Open Arnie Bot in a floating terminal window
function M.open_terminal()
  local width = math.floor(vim.o.columns * 0.8)
  local height = math.floor(vim.o.lines * 0.8)
  local col = math.floor((vim.o.columns - width) / 2)
  local row = math.floor((vim.o.lines - height) / 2)

  local buf = vim.api.nvim_create_buf(false, true)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    col = col,
    row = row,
    style = 'minimal',
    border = 'rounded',
    title = session.session_id and ' Arnie Bot (session) ' or ' Arnie Bot ',
    title_pos = 'center',
  })

  local cmd = 'claude'
  if session.session_id then
    cmd = cmd .. ' --resume ' .. session.session_id
    vim.notify('Resuming session: ' .. session.session_id, vim.log.levels.INFO)
  else
    vim.notify('No session to resume, starting fresh', vim.log.levels.INFO)
  end

  vim.fn.termopen(cmd, {
    on_exit = function()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end,
  })

  vim.keymap.set('t', '<Esc>', function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end, { buffer = buf, desc = 'Close Arnie Bot terminal' })

  vim.cmd 'startinsert'
end

-- Cancel current running job
function M.cancel()
  if M.current_response then
    M.stop_spinner()
    if M.current_response.job_id then
      vim.fn.jobstop(M.current_response.job_id)
    end
    M.show_inline(M.current_response.buf, M.current_response.position, { 'Cancelled.' }, false)
    M.current_response = nil
  end
end

-- Execute Arnie Bot CLI with prompt and show inline
function M.execute_arnie_inline(prompt, position, use_session)
  local buf = position.buf

  -- Cancel any existing job and timer
  if M.current_response then
    M.stop_spinner()
    if M.current_response.job_id then
      vim.fn.jobstop(M.current_response.job_id)
    end
  end

  M.current_response = {
    buf = buf,
    position = position,
    job_id = nil,
    timer = nil,
    start_time = vim.loop.now(),
  }

  -- Start loading animation
  local spinner_idx = 1
  local timer = vim.loop.new_timer()
  M.current_response.timer = timer

  timer:start(
    0,
    100,
    vim.schedule_wrap(function()
      if M.current_response and M.current_response.timer then
        local elapsed = math.floor((vim.loop.now() - M.current_response.start_time) / 1000)
        local spinner = M.spinner_frames[spinner_idx]
        M.show_inline(buf, position, {
          spinner .. ' Thinking... (' .. elapsed .. 's)',
        }, true)
        spinner_idx = (spinner_idx % #M.spinner_frames) + 1
      end
    end)
  )

  local claude_path = vim.fn.exepath 'claude'
  if claude_path == '' then
    M.stop_spinner()
    M.show_inline(buf, position, { 'Error: claude CLI not found in PATH' }, false)
    return
  end

  local received_output = false
  local json_output = ''

  local cmd_args = { claude_path, '-p' }

  if M.config.model then
    table.insert(cmd_args, '--model')
    table.insert(cmd_args, M.config.model)
  end

  if M.config.skip_permissions then
    table.insert(cmd_args, '--dangerously-skip-permissions')
  end

  if use_session and session.session_id then
    table.insert(cmd_args, '--resume')
    table.insert(cmd_args, session.session_id)
    vim.notify('Resuming: ' .. session.session_id:sub(1, 8) .. '...', vim.log.levels.INFO)
  elseif use_session then
    vim.notify('Starting new session (no previous session)', vim.log.levels.INFO)
  end

  table.insert(cmd_args, '--output-format')
  table.insert(cmd_args, 'json')

  if not M.config.allow_tools then
    table.insert(cmd_args, '--allowedTools')
    table.insert(cmd_args, '')
  elseif M.config.allowed_tools then
    table.insert(cmd_args, '--allowedTools')
    table.insert(cmd_args, table.concat(M.config.allowed_tools, ' '))
  end

  local job_id = vim.fn.jobstart(cmd_args, {
    stdin = 'pipe',
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      if data then
        for _, chunk in ipairs(data) do
          if chunk ~= '' then
            json_output = json_output .. chunk
            if not received_output then
              received_output = true
              vim.schedule(function()
                M.stop_spinner()
                M.show_inline(buf, position, { '⟳ Working...' }, true)
              end)
            end
          end
        end
      end
    end,
    on_stderr = function()
      -- Silently ignore stderr
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        M.stop_spinner()

        if json_output ~= '' and use_session then
          local ok, parsed = pcall(vim.fn.json_decode, json_output)
          if ok and parsed and parsed.session_id then
            session.session_id = parsed.session_id
            session.persist()
            vim.notify('Session saved: ' .. parsed.session_id:sub(1, 8) .. '...', vim.log.levels.INFO)
          end
        end

        vim.cmd 'silent! checktime'
        if vim.api.nvim_buf_is_valid(buf) and not vim.bo[buf].modified then
          vim.api.nvim_buf_call(buf, function()
            vim.cmd 'silent! e'
          end)
        end

        if M.current_response then
          local elapsed = math.floor((vim.loop.now() - M.current_response.start_time) / 1000)
          if code == 0 then
            local session_indicator = session.session_id and ' [session]' or ''
            M.show_inline(buf, position, { '✓ Done (' .. elapsed .. 's)' .. session_indicator }, false)
            vim.defer_fn(function()
              M.dismiss()
            end, 2000)
          else
            M.show_inline(buf, position, {
              '✗ Error (exit code: ' .. code .. ')',
            }, false)
          end
          M.current_response.job_id = nil
        end
      end)
    end,
  })

  if job_id <= 0 then
    M.stop_spinner()
    M.show_inline(buf, position, {
      'Error: Failed to start job',
      'Job ID: ' .. job_id,
    }, false)
    return
  end

  M.current_response.job_id = job_id

  local send_ok = vim.fn.chansend(job_id, prompt)
  if send_ok == 0 then
    M.stop_spinner()
    M.show_inline(buf, position, { 'Error: Failed to send prompt to stdin' }, false)
    return
  end
  vim.fn.chanclose(job_id, 'stdin')
end

-- Floating prompt window
function M.prompt_window(use_session, callback)
  local hl_ns = vim.api.nvim_create_namespace 'arnie-skill-highlight'

  local width = math.floor(vim.o.columns * 0.6)
  local height = math.floor(vim.o.lines * 0.2)
  local col = math.floor((vim.o.columns - width) / 2)
  local row = math.floor((vim.o.lines - height) / 2)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, 'arnie-prompt')
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'markdown'

  local title = ' Prompt'
  if use_session and session.session_id then
    title = title .. ' [session]'
  end
  title = title .. ' (:w submit, q cancel) '

  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    col = col,
    row = row,
    style = 'minimal',
    border = 'rounded',
    title = title,
    title_pos = 'center',
  })

  vim.wo[win].wrap = true
  vim.wo[win].number = false

  local function highlight_skills()
    vim.api.nvim_buf_clear_namespace(buf, hl_ns, 0, -1)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local loaded_skills = skills.load_skills()

    for line_num, line in ipairs(lines) do
      local line_lower = line:lower()
      for _, skill in pairs(loaded_skills) do
        for _, keyword in ipairs(skill.keywords) do
          local start_idx = 1
          while true do
            local match_start = line_lower:find(keyword, start_idx, true)
            if not match_start then
              break
            end
            if skills.is_whole_word(line_lower, match_start, #keyword) then
              vim.api.nvim_buf_add_highlight(buf, hl_ns, 'DiagnosticInfo', line_num - 1, match_start - 1, match_start - 1 + #keyword)
            end
            start_idx = match_start + 1
          end
        end
      end
    end
  end

  local group = vim.api.nvim_create_augroup('arnie_prompt_' .. buf, { clear = true })

  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
    group = group,
    buffer = buf,
    callback = highlight_skills,
  })

  vim.api.nvim_create_autocmd('BufWriteCmd', {
    group = group,
    buffer = buf,
    callback = function()
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local prompt = vim.trim(table.concat(lines, '\n'))
      vim.bo[buf].modified = false
      vim.api.nvim_win_close(win, true)
      if prompt ~= '' then
        callback(prompt)
      end
    end,
  })

  vim.keymap.set('n', '<CR>', function()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local prompt = vim.trim(table.concat(lines, '\n'))
    vim.api.nvim_win_close(win, true)
    if prompt ~= '' then
      callback(prompt)
    end
  end, { buffer = buf, nowait = true })

  vim.keymap.set('n', 'q', function()
    vim.api.nvim_win_close(win, true)
  end, { buffer = buf, nowait = true })

  vim.keymap.set('n', '<Esc>', function()
    vim.api.nvim_win_close(win, true)
  end, { buffer = buf, nowait = true })

  vim.cmd 'startinsert'
end

-- Main function: ask Arnie Bot about selected code (or entire file in normal mode)
function M.ask(use_visual, use_session)
  local selection, position

  if use_visual then
    selection, position = M.get_visual_selection()
    if not selection or selection == '' then
      vim.notify('No text selected', vim.log.levels.WARN)
      return
    end
  else
    local buf = vim.api.nvim_get_current_buf()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    if #lines == 0 then
      vim.notify('File is empty', vim.log.levels.WARN)
      return
    end
    selection = table.concat(lines, '\n')
    position = {
      start_line = 1,
      end_line = #lines,
      start_col = 1,
      end_col = #lines[#lines] or 1,
      buf = buf,
    }
  end

  local context = M.get_context()

  M.prompt_window(use_session, function(user_prompt)
    local skill_name, skill = skills.detect_skill(user_prompt)
    local skill_context = ''

    if skill then
      skill_context = string.format('\n\nSkill [%s]:\n%s', skill_name, skill.context)
      vim.notify('Skill detected: ' .. skill_name, vim.log.levels.INFO)
    end

    local full_prompt = string.format(
      [[Edit the selected code in %s (lines %d-%d). Use the Edit tool to replace ONLY this code:

```%s
%s
```

Task: %s%s

Just make the edit. No explanation needed.]],
      context.filepath,
      position.start_line,
      position.end_line,
      context.filetype,
      selection,
      user_prompt,
      skill_context
    )

    M.execute_arnie_inline(full_prompt, position, use_session)
  end)
end

-- Setup function
function M.setup(opts)
  opts = opts or {}
  M.config = vim.tbl_deep_extend('force', M.config, opts)

  -- Restore the last active session for this project
  session.load_saved()

  vim.keymap.set('n', M.config.keymaps.ask, function()
    M.ask(false, false)
  end, { desc = 'Ask Arnie Bot (entire file)' })

  vim.keymap.set('v', M.config.keymaps.ask, function()
    M.ask(true, false)
  end, { desc = 'Ask Arnie Bot (selection)' })

  vim.keymap.set('n', M.config.keymaps.ask_continue, function()
    M.ask(false, true)
  end, { desc = 'Ask Arnie Bot (entire file, continue session)' })

  vim.keymap.set('v', M.config.keymaps.ask_continue, function()
    M.ask(true, true)
  end, { desc = 'Ask Arnie Bot (selection, continue session)' })

  vim.keymap.set('n', M.config.keymaps.terminal, function()
    M.open_terminal()
  end, { desc = 'Open Arnie Bot terminal' })

  vim.keymap.set('n', M.config.keymaps.dismiss, function()
    M.dismiss()
  end, { desc = 'Dismiss Arnie Bot response' })

  vim.keymap.set('n', M.config.keymaps.cancel, function()
    M.cancel()
  end, { desc = 'Cancel Arnie Bot request' })

  vim.keymap.set('n', M.config.keymaps.sessions, function()
    session.pick_session(function(s)
      session.restore(s.id)
    end)
  end, { desc = 'Browse Arnie Bot sessions' })
end

return M
