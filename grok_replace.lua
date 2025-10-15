local M = {}

-- Default configuration.
local config = {
  model = "grok-4-fast",
  system_prompt = [[You should replace the code that you are sent, only following the comments. Do not talk at all. Only output valid code. Do not provide any backticks that surround the code. Never ever output backticks like this ```. Any comment that is asking you for something should be removed after you satisfy them. Other comments should left alone.]]
}

-- local output_file = vim.fn.stdpath("cache") .. "/grok_stream.log"
-- local log_file = vim.fn.stdpath("cache") .. "/grok_replace.log"

-- local function log_message(msg)
--   local file = io.open(log_file, "a")
--   if file then
--     file:write(os.date("%Y-%m-%d %H:%M:%S") .. " " .. tostring(msg) .. "\n")
--     file:close()
--   else
--     vim.notify("Could not open log file: " .. log_file, vim.log.levels.ERROR)
--   end
-- end

local function format_full_content(content)
  if not content or content == "" then
    return ""
  end

  -- Remove leading/trailing whitespace
  content = content:gsub("^%s*", ""):gsub("%s*$", "")

  -- Remove entire code blocks if present (full response)
  content = content:gsub("^```[%w_]*%s*\n", ""):gsub("\n%s*```$", "")

  -- Remove any remaining partial fences or lang ids at start/end
  content = content:gsub("^[%w_]*%s*\n", "")
  content = content:gsub("\n[%w_]*%s*$", "")

  -- Clean up common artifacts: extra newlines, escaped quotes (though JSON handles most)
  content = content:gsub("\\n", "\n"):gsub('\\"', '"'):gsub("\\\\", "\\")

  -- Normalize single newlines to ensure consistent line breaks
  content = content:gsub("\r\n?", "\n")

  -- Add markdown-friendly spacing: Ensure double newlines after headings (##, ###), before/after lists (1., -), and between paragraphs
  -- After headings: ## Text\n -> ## Text\n\n
  content = content:gsub("^(#+ .+?)\n", "%1\n\n")
  -- Before numbered/bulleted lists: Text\n1. -> Text\n\n1.
  content = content:gsub("(%n?)([%d]+%s*%.|%-) ", "%1\n\n%2 ")
  -- After list items if single-spaced: 1. Item\n2. -> 1. Item\n\n2.
  content = content:gsub("([%d]+%s*%.|%- .+?)\n([%d]+%s*%.|%- )", "%1\n\n%2")
  -- Between paragraphs (non-empty lines separated by single \n): Line\nLine -> Line\n\nLine
  content = content:gsub("([^\n]+)\n([^\n]+)", "%1\n\n%2")
  -- Trim excessive newlines at end/start but keep doubles
  content = content:gsub("^\n+", "\n"):gsub("\n+$", "\n"):gsub("\n{3,}", "\n\n")

  return content
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
  local end_col_idx = end_pos[3] - 1  -- 0-based exclusive end column

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
  local line_len = #last_line_text
  if end_col_idx > line_len then
    end_col_idx = line_len
  end

  -- Remove the selected text.
  vim.api.nvim_buf_set_text(buf, start_line_idx, start_col_idx, end_line_idx, end_col_idx, {})

  -- Set initial insertion position
  local insertion_row = start_line_idx
  local insertion_col = start_col_idx

  -- Line buffer for streaming
  local line_buffer = ""
  local full_inserted_range = {start_row = insertion_row, start_col = insertion_col, end_row = insertion_row, end_col = insertion_col}  -- Track inserted block for final cleanup

  ----------------------------------------
  ----------------- grok -----------------
  ----------------------------------------
  local grok_payload = {
    model = config.model,
    system = config.system_prompt,
    temperature = 0,
    stream = true,
    messages = {
      { role = "user", content = original_text }
    }
  }

  local json_grok_payload = vim.fn.json_encode(grok_payload)
  -- log_message("Payload: " .. json_grok_payload)

  local grok_args = {
    "-s",
    "-X", "POST",
    "https://api.x.ai/v1/chat/completions",
    "-H", "Content-Type: application/json",
    "-H", "Authorization: Bearer " .. os.getenv("GROK_API_KEY"),
    "-d", json_grok_payload,
    "--no-buffer"
  }

  local Job = require("plenary.job")
  Job:new({
    command = "curl",
    args = grok_args,
    on_stdout = function(_, line)
      -- log_message("Raw line: " .. line)

      -- Parse SSE format: "data: {...}"
      if line:match("^data: ") then
        local json_str = line:gsub("^data: ", "")

        -- Skip [DONE] marker
        if json_str == "[DONE]" then
          -- Flush final buffer and clean up
          if line_buffer ~= "" then
            local final_line = line_buffer .. "\n"
            vim.schedule(function()
              local new_lines = vim.split(final_line, "\n")
              vim.api.nvim_buf_set_text(buf, insertion_row, insertion_col, insertion_row, insertion_col, new_lines)
              -- Update positions
              insertion_row = insertion_row + #new_lines - 1
              insertion_col = #new_lines[#new_lines]
              full_inserted_range.end_row = insertion_row
              full_inserted_range.end_col = insertion_col
            end)
          end
          return
        end

        -- Defer JSON parsing to main thread
        vim.schedule(function()
          local ok, parsed = pcall(vim.fn.json_decode, json_str)
          if ok and parsed and parsed.choices and parsed.choices[1] then
            local delta = parsed.choices[1].delta
            if delta and delta.content then
              line_buffer = line_buffer .. delta.content
              -- log_message("Buffer so far: " .. line_buffer)  -- Debug

              -- Insert on newline (full line ready)
              local pos = line_buffer:find("\n")
              while pos do
                local ready_line = line_buffer:sub(1, pos)
                line_buffer = line_buffer:sub(pos + 1)

                if ready_line ~= "\n" then  -- Skip empty lines
                  local new_lines = vim.split(ready_line, "\n")
                  vim.api.nvim_buf_set_text(buf, insertion_row, insertion_col, insertion_row, insertion_col, new_lines)
                  -- Update positions
                  local num_new = #new_lines
                  insertion_row = insertion_row + num_new - 1
                  insertion_col = #new_lines[num_new]
                  full_inserted_range.end_row = insertion_row
                  full_inserted_range.end_col = insertion_col
                end

                pos = line_buffer:find("\n")
              end
            end
          else
            -- log_message("JSON parse failed: " .. (parsed or "nil"))
          end
        end)
      end
    end,
    on_stderr = function(_, line)
      if line then
        -- log_message("Stderr: " .. line)
      end
    end,
    on_exit = function(_)
      vim.schedule(function()
        -- Final cleanup: Reformat the entire inserted block with improved markdown spacing
        local inserted_lines = vim.api.nvim_buf_get_lines(buf, full_inserted_range.start_row, full_inserted_range.end_row + 1, false)
        local raw_content = table.concat(inserted_lines, "\n")
        local cleaned = format_full_content(raw_content)

        if cleaned ~= raw_content then
          local clean_lines = vim.split(cleaned, "\n")
          vim.api.nvim_buf_set_text(buf, full_inserted_range.start_row, full_inserted_range.start_col, full_inserted_range.end_row, full_inserted_range.end_col, clean_lines)
        end

        vim.cmd("write")
        -- log_message("Streaming complete - inserted " .. (#inserted_lines) .. " lines")
      end)
    end,
  }):start()
end

return M
