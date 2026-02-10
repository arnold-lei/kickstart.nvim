local M = {}

M.config = {
  keymaps = {
    ask = '<leader>ca',
    ask_continue = '<leader>cA',
    terminal = '<leader>ct',
    dismiss = '<leader>cd',
    cancel = '<leader>cx',
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

-- Parse YAML frontmatter from SKILL.md content
function M.parse_skill_frontmatter(content)
  local frontmatter = {}
  local body = content

  -- Check for YAML frontmatter (starts with ---)
  if content:match '^%-%-%-\n' then
    local yaml_end = content:find('\n%-%-%-\n', 4)
    if yaml_end then
      local yaml_content = content:sub(5, yaml_end - 1)
      body = content:sub(yaml_end + 5)

      -- Parse simple YAML key: value pairs
      for line in yaml_content:gmatch '[^\n]+' do
        local key, value = line:match '^([%w%-]+):%s*(.+)$'
        if key and value then
          frontmatter[key] = value
        end
      end
    end
  end

  return frontmatter, vim.trim(body)
end

-- Load skills from .claude/skills/*/SKILL.md files
function M.load_skills()
  local skills = {}
  local cwd = vim.fn.getcwd()
  local skills_dir = cwd .. '/.claude/skills'

  -- Check if skills directory exists
  if vim.fn.isdirectory(skills_dir) == 0 then
    return skills
  end

  -- Get all subdirectories
  local handle = vim.loop.fs_scandir(skills_dir)
  if not handle then
    return skills
  end

  while true do
    local name, type = vim.loop.fs_scandir_next(handle)
    if not name then
      break
    end

    if type == 'directory' then
      local skill_file = skills_dir .. '/' .. name .. '/SKILL.md'
      if vim.fn.filereadable(skill_file) == 1 then
        local content = table.concat(vim.fn.readfile(skill_file), '\n')
        local frontmatter, body = M.parse_skill_frontmatter(content)

        -- Get keywords from frontmatter or use directory name
        local keywords = {}
        if frontmatter.keywords then
          for keyword in frontmatter.keywords:gmatch '[^,]+' do
            table.insert(keywords, vim.trim(keyword):lower())
          end
        else
          -- Use directory name and skill name as default keywords
          table.insert(keywords, name:lower())
          if frontmatter.name and frontmatter.name:lower() ~= name:lower() then
            table.insert(keywords, frontmatter.name:lower())
          end
        end

        skills[name] = {
          name = frontmatter.name or name,
          description = frontmatter.description,
          keywords = keywords,
          context = body,
        }
      end
    end
  end

  return skills
end

-- Check if a keyword match is a whole word (has word boundaries)
function M.is_whole_word(str, start_idx, keyword_len)
  local before_ok = start_idx == 1 or not str:sub(start_idx - 1, start_idx - 1):match '[%w]'
  local after_idx = start_idx + keyword_len
  local after_ok = after_idx > #str or not str:sub(after_idx, after_idx):match '[%w]'
  return before_ok and after_ok
end

-- Detect skill from user prompt
function M.detect_skill(prompt)
  local skills = M.load_skills()
  local prompt_lower = prompt:lower()

  for skill_name, skill in pairs(skills) do
    for _, keyword in ipairs(skill.keywords) do
      local start_idx = 1
      while true do
        local match_start = prompt_lower:find(keyword, start_idx, true)
        if not match_start then
          break
        end
        if M.is_whole_word(prompt_lower, match_start, #keyword) then
          return skill_name, skill
        end
        start_idx = match_start + 1
      end
    end
  end

  return nil, nil
end

-- Namespace for virtual text
M.ns = vim.api.nvim_create_namespace 'arnie-bot'

-- Track current inline response state
M.current_response = nil

-- Track session ID for conversation continuity
M.session_id = nil

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

  -- Add response lines
  for _, text in ipairs(lines) do
    table.insert(bottom_virt, { { '│ ' .. text, 'Comment' } })
  end

  -- Add bottom border
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

-- Start a new session (clear session ID)
function M.new_session()
  M.session_id = nil
  vim.notify('Arnie Bot: New session started', vim.log.levels.INFO)
end

-- Debug: show current session state
function M.debug()
  if M.session_id then
    vim.notify('Session ID: ' .. M.session_id, vim.log.levels.INFO)
  else
    vim.notify('No active session', vim.log.levels.WARN)
  end
end

-- Open Arnie Bot in a floating terminal window
function M.open_terminal()
  -- Calculate floating window size (80% of editor)
  local width = math.floor(vim.o.columns * 0.8)
  local height = math.floor(vim.o.lines * 0.8)
  local col = math.floor((vim.o.columns - width) / 2)
  local row = math.floor((vim.o.lines - height) / 2)

  -- Create buffer for terminal
  local buf = vim.api.nvim_create_buf(false, true)

  -- Create floating window
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    col = col,
    row = row,
    style = 'minimal',
    border = 'rounded',
    title = M.session_id and ' Arnie Bot (session) ' or ' Arnie Bot ',
    title_pos = 'center',
  })

  -- Build command
  local cmd = 'claude'
  if M.session_id then
    cmd = cmd .. ' --resume ' .. M.session_id
    vim.notify('Resuming session: ' .. M.session_id, vim.log.levels.INFO)
  else
    vim.notify('No session to resume, starting fresh', vim.log.levels.INFO)
  end

  -- Open terminal with Arnie Bot
  vim.fn.termopen(cmd, {
    on_exit = function()
      -- Close window when Arnie Bot exits
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end,
  })

  -- Map Esc to close the terminal window
  vim.keymap.set('t', '<Esc>', function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end, { buffer = buf, desc = 'Close Arnie Bot terminal' })

  -- Enter insert mode for terminal
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

  -- Store current response state
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

  -- Find claude CLI path
  local claude_path = vim.fn.exepath 'claude'
  if claude_path == '' then
    M.stop_spinner()
    M.show_inline(buf, position, { 'Error: claude CLI not found in PATH' }, false)
    return
  end

  local received_output = false
  local json_output = ''

  -- Build command args
  local cmd_args = { claude_path, '-p' }

  -- Set model if specified
  if M.config.model then
    table.insert(cmd_args, '--model')
    table.insert(cmd_args, M.config.model)
  end

  -- Skip permission checks if enabled
  if M.config.skip_permissions then
    table.insert(cmd_args, '--dangerously-skip-permissions')
  end

  -- Add session continuity if requested and available
  if use_session and M.session_id then
    table.insert(cmd_args, '--resume')
    table.insert(cmd_args, M.session_id)
    vim.notify('Resuming: ' .. M.session_id:sub(1, 8) .. '...', vim.log.levels.INFO)
  elseif use_session then
    vim.notify('Starting new session (no previous session)', vim.log.levels.INFO)
  end

  -- Use JSON output to capture session ID
  table.insert(cmd_args, '--output-format')
  table.insert(cmd_args, 'json')

  if not M.config.allow_tools then
    -- Disable all tools to prevent permission prompts
    table.insert(cmd_args, '--allowedTools')
    table.insert(cmd_args, '')
  elseif M.config.allowed_tools then
    -- Allow specific tools
    table.insert(cmd_args, '--allowedTools')
    table.insert(cmd_args, table.concat(M.config.allowed_tools, ' '))
  end
  -- If allow_tools is true and allowed_tools is nil, all tools are allowed

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
        -- Stop the spinner animation
        M.stop_spinner()

        -- Parse JSON output to extract session_id
        if json_output ~= '' and use_session then
          local ok, parsed = pcall(vim.fn.json_decode, json_output)
          if ok and parsed and parsed.session_id then
            M.session_id = parsed.session_id
            vim.notify('Session saved: ' .. parsed.session_id:sub(1, 8) .. '...', vim.log.levels.INFO)
          end
        end

        -- Reload any files that Arnie Bot may have modified
        -- checktime will reload buffers if autoread is enabled
        vim.cmd 'silent! checktime'
        -- Force reload the specific buffer we were working on
        if vim.api.nvim_buf_is_valid(buf) and not vim.bo[buf].modified then
          vim.api.nvim_buf_call(buf, function()
            vim.cmd 'silent! e'
          end)
        end

        if M.current_response then
          local elapsed = math.floor((vim.loop.now() - M.current_response.start_time) / 1000)
          if code == 0 then
            -- Success - show brief done message with session indicator
            local session_indicator = M.session_id and ' [session]' or ''
            M.show_inline(buf, position, { '✓ Done (' .. elapsed .. 's)' .. session_indicator }, false)
            -- Auto-dismiss after 2 seconds
            vim.defer_fn(function()
              M.dismiss()
            end, 2000)
          else
            -- Error - show error info
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

  -- Send prompt via stdin and close
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

  -- Calculate window size (60% width, 20% height, centered)
  local width = math.floor(vim.o.columns * 0.6)
  local height = math.floor(vim.o.lines * 0.2)
  local col = math.floor((vim.o.columns - width) / 2)
  local row = math.floor((vim.o.lines - height) / 2)

  -- Create buffer
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, 'arnie-prompt')
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'markdown'

  -- Build title with session indicator
  local title = ' Prompt'
  if use_session and M.session_id then
    title = title .. ' [session]'
  end
  title = title .. ' (:w submit, q cancel) '

  -- Create window
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

  -- Function to highlight skill keywords
  local function highlight_skills()
    vim.api.nvim_buf_clear_namespace(buf, hl_ns, 0, -1)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local skills = M.load_skills()

    for line_num, line in ipairs(lines) do
      local line_lower = line:lower()
      for _, skill in pairs(skills) do
        for _, keyword in ipairs(skill.keywords) do
          local start_idx = 1
          while true do
            local match_start = line_lower:find(keyword, start_idx, true)
            if not match_start then
              break
            end
            if M.is_whole_word(line_lower, match_start, #keyword) then
              vim.api.nvim_buf_add_highlight(buf, hl_ns, 'DiagnosticInfo', line_num - 1, match_start - 1, match_start - 1 + #keyword)
            end
            start_idx = match_start + 1
          end
        end
      end
    end
  end

  -- Create autocommand group
  local group = vim.api.nvim_create_augroup('arnie_prompt_' .. buf, { clear = true })

  -- Highlight on text change
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
    group = group,
    buffer = buf,
    callback = highlight_skills,
  })

  -- Submit on save
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

  -- Also submit with <CR> in normal mode
  vim.keymap.set('n', '<CR>', function()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local prompt = vim.trim(table.concat(lines, '\n'))
    vim.api.nvim_win_close(win, true)
    if prompt ~= '' then
      callback(prompt)
    end
  end, { buffer = buf, nowait = true })

  -- Cancel with q
  vim.keymap.set('n', 'q', function()
    vim.api.nvim_win_close(win, true)
  end, { buffer = buf, nowait = true })

  -- Cancel with Esc
  vim.keymap.set('n', '<Esc>', function()
    vim.api.nvim_win_close(win, true)
  end, { buffer = buf, nowait = true })

  -- Start in insert mode
  vim.cmd 'startinsert'
end

-- Main function: ask Arnie Bot about selected code (or entire file in normal mode)
function M.ask(use_visual, use_session)
  local selection, position

  if use_visual then
    -- Visual mode: use selection
    selection, position = M.get_visual_selection()
    if not selection or selection == '' then
      vim.notify('No text selected', vim.log.levels.WARN)
      return
    end
  else
    -- Normal mode: use entire file
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
    -- Detect skill from prompt
    local skill_name, skill = M.detect_skill(user_prompt)
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

  -- Set up keymap for normal mode (entire file, no session)
  vim.keymap.set('n', M.config.keymaps.ask, function()
    M.ask(false, false)
  end, { desc = 'Ask Arnie Bot (entire file)' })

  -- Set up keymap for visual mode (selection, no session)
  vim.keymap.set('v', M.config.keymaps.ask, function()
    M.ask(true, false)
  end, { desc = 'Ask Arnie Bot (selection)' })

  -- Set up keymap for normal mode with session continuity
  vim.keymap.set('n', M.config.keymaps.ask_continue, function()
    M.ask(false, true)
  end, { desc = 'Ask Arnie Bot (entire file, continue session)' })

  -- Set up keymap for visual mode with session continuity
  vim.keymap.set('v', M.config.keymaps.ask_continue, function()
    M.ask(true, true)
  end, { desc = 'Ask Arnie Bot (selection, continue session)' })

  -- Set up keymap to open terminal
  vim.keymap.set('n', M.config.keymaps.terminal, function()
    M.open_terminal()
  end, { desc = 'Open Arnie Bot terminal' })

  -- Set up keymap to dismiss inline response
  vim.keymap.set('n', M.config.keymaps.dismiss, function()
    M.dismiss()
  end, { desc = 'Dismiss Arnie Bot response' })

  -- Set up keymap to cancel running request
  vim.keymap.set('n', M.config.keymaps.cancel, function()
    M.cancel()
  end, { desc = 'Cancel Arnie Bot request' })
end

return M
