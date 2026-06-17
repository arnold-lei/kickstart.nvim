local M = {}

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

-- Check if a keyword match is a whole word (has word boundaries)
function M.is_whole_word(str, start_idx, keyword_len)
  local before_ok = start_idx == 1 or not str:sub(start_idx - 1, start_idx - 1):match '[%w]'
  local after_idx = start_idx + keyword_len
  local after_ok = after_idx > #str or not str:sub(after_idx, after_idx):match '[%w]'
  return before_ok and after_ok
end

-- Load skills from .claude/skills/*/SKILL.md files
function M.load_skills()
  local skills = {}
  local cwd = vim.fn.getcwd()
  local skills_dir = cwd .. '/.claude/skills'

  if vim.fn.isdirectory(skills_dir) == 0 then
    return skills
  end

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

        local keywords = {}
        if frontmatter.keywords then
          for keyword in frontmatter.keywords:gmatch '[^,]+' do
            table.insert(keywords, vim.trim(keyword):lower())
          end
        else
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

return M
