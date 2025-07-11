local M = {}

-- Default configuration.
local config = {
  model = "grok-4-0709",
  system_prompt = [[You should replace the code that you are sent, only following the comments. Do not talk at all. Only output valid code. Do not provide any backticks that surround the code. Never ever output backticks like this ```. Any comment that is asking you for something should be removed after you satisfy them. Other comments should left alone.]]
}

local output_file = vim.fn.stdpath("cache") .. "/grok_stream.log"
local log_file = vim.fn.stdpath("cache") .. "/grok_replace.log"

local function log_message(msg)
  local file = io.open(log_file, "a")
  if file then
    file:write(os.date("%Y-%m-%d %H:%M:%S") .. " " .. tostring(msg) .. "\n")
    file:close()
  else
    vim.notify("Could not open log file: " .. log_file, vim.log.levels.ERROR)
  end
end

local function append_to_output_file(data)
  local file = io.open(output_file, "a")
  if file then
    file:write(data)
    file:close()
  else
    log_message("Failed to open output file: " .. output_file)
  end
end

local function format_chunk(chunk)
  if not chunk then
    return ""
  end
  
  -- Basic text cleanup.
  chunk = chunk:gsub('\\\"', '"')
  chunk = chunk:gsub('\\n', '\n')
  
  -- Remove language identifier if present
  chunk = chunk:gsub('^%s*[%w_]+%s*\n', '')
  chunk = chunk:gsub('^%s*[pP][yY][tT][hH][oO][nN]%s*\n', '')
  chunk = chunk:gsub('^%s*[pP][yY][tT][hH][oO][nN]%s*$', '')
  
  -- Replace single line 'python' with nothing
  if chunk:match('^%s*[pP][yY][tT][hH][oO][nN]%s*$') then
    return ""
  end
  
  return chunk
end

local function write_string_at_cursor(str)
  vim.schedule(function()
    local current_window = vim.api.nvim_get_current_win()
    local cursor_position = vim.api.nvim_win_get_cursor(current_window)
    local row, col = cursor_position[1], cursor_position[2]
    
    local lines = vim.split(str, '\n')
    vim.cmd("undojoin")
    vim.api.nvim_put(lines, 'c', true, true)
    
    local num_lines = #lines
    local last_line_length = #lines[num_lines]
    vim.api.nvim_win_set_cursor(current_window, { row + num_lines - 1, col + last_line_length })
  end)
end

function M.setup(user_config)
  if user_config then
    config = vim.tbl_extend("force", config, user_config)
  end
  vim.api.nvim_create_user_command("GrokReplace", function()
    M.replace_with_grok()
  end, { range = true, desc = "Replace selected text with Xai's Grok-4 response" })
end

function M.replace_with_grok()
  local buf = 0 -- current buffer
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local start_line, start_col = start_pos[2], start_pos[3]
  local end_line, end_col = end_pos[2], end_pos[3]
  local start_line_idx = start_line - 1
  local start_col_idx = start_col - 1
  local end_line_idx = end_line - 1
  local end_col_idx = end_col

  -- Retrieve the selected text to use as the prompt.
  local original_lines = vim.api.nvim_buf_get_lines(buf, start_line_idx, end_line, false)
  if not original_lines or #original_lines == 0 then
    vim.notify("No text selected", vim.log.levels.WARN)
    return
  end
  original_lines[1] = string.sub(original_lines[1], start_col)
  original_lines[#original_lines] = string.sub(original_lines[#original_lines], 1, end_col)
  local original_text = table.concat(original_lines, "\n")

  -- Clamp end_col_idx.
  local last_line_text = vim.api.nvim_buf_get_lines(buf, end_line_idx, end_line_idx + 1, false)[1] or ""
  if end_col_idx > #last_line_text then
    end_col_idx = #last_line_text
  end

  -- Remove the selected text.
  vim.api.nvim_buf_set_text(buf, start_line_idx, start_col_idx, end_line_idx, end_col_idx, {})

  -- Insert an empty line at the insertion point.
  vim.api.nvim_buf_set_lines(buf, start_line_idx, start_line_idx, false, {""})

  ----------------------------------------
  ----------------- grok -----------------
  ----------------------------------------
  local grok_payload = {
    model = config.model,
    system = config.system_prompt,
    temperature = 0,
    messages = {
      { role = "user", content = original_text }
    }
  }

  local json_grok_payload = vim.fn.json_encode(grok_payload)
  log_message("Payload: " .. json_grok_payload)

  local grok_args = {
    "-s",
    "-X", "POST",
    "https://api.x.ai/v1/chat/completions",
    "-H", "Content-Type: application/json",
    "-H", "Authorization: Bearer " .. os.getenv("YOUR_XAI_API_KEY"),
    "-d", json_grok_payload,
    "--no-buffer"
  }

  local Job = require("plenary.job")
  Job:new({
    command = "curl",
    args = grok_args,
    on_stdout = function(_, line)
      log_message("Raw line: " .. line)
      
      local code
      if line:match("```") then
        code = line:match("```%s*([%s%S]-)```")
      else
        -- If no code blocks, check for content field
        local ok, parsed = pcall(vim.fn.json_decode, line)
        if ok and parsed and parsed.choices and parsed.choices[1] and 
           parsed.choices[1].message and parsed.choices[1].message.content then
          code = parsed.choices[1].message.content
        end
      end
      
      if code then
        code = format_chunk(code)
        write_string_at_cursor(code)
      end
    end,
    on_stderr = function(_, line)
      if line then
        log_message("Stderr: " .. line)
        append_to_output_file("\nStderr: " .. line .. "\n")
      end
    end,
    on_exit = function(_)
      vim.schedule(function()
        vim.cmd("write")
      end)
    end,
  }):start()
end

return M

