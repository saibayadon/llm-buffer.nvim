---@class LLMBufferConfig
---@field window_width? number Width of the floating window (0-1)
---@field window_height? number Height of the floating window (0-1)
---@field anthropic_api_key? string|nil API key for Anthropic
---@field gemini_api_key? string|nil API key for Gemini
---@field ollama_api_host? string|nil API host for Ollama
---@field openai_api_key? string|nil API key for OpenAI
---@field provider? "anthropic"|"gemini"|"openai"|"ollama" The LLM provider to use
---@field model? string The model to use for completion
---@field system_prompt? string The system prompt to use
---@field mappings? LLMBufferMappings Key mappings configuration

---@class LLMBufferMappings
---@field send_prompt? string Keymap to send the prompt
---@field close_window? string Keymap to close the window
---@field toggle_window? string Keymap to toggle the window

local M = { win_opts = {} }
local Job = require("plenary.job")

local active_job = nil
local llm_buf = nil
local llm_win = nil
local was_cancelled = false
local conversation_history = {}
local MAX_HISTORY_MESSAGES = 10

---@type LLMBufferConfig
M.defaults = {
	window_width = 0.85,
	window_height = 0.85,
	anthropic_api_key = os.getenv("ANTHROPIC_API_KEY"),
	openai_api_key = os.getenv("OPENAI_API_KEY"),
	gemini_api_key = os.getenv("GEMINI_API_KEY"),
	ollama_api_host = "http://localhost:11434",
	provider = "anthropic", -- "anthropic", "gemini", "openai" or "ollama"
	model = "claude-3-7-sonnet-latest", -- "claude-3-7-sonnet-latest", "gemini-2.0-flash" or "gpt-4o-mini"
	system_prompt = [[
    You are a helpful AI coding assistant with expertise in computer science and software development.

    ## Guidelines:
    - Format your responses using proper Markdown syntax
    - Use syntax-highlighted code blocks with language identifiers (```python, ```lua, etc.)
    - Be concise and direct in your explanations
    - Provide practical, working examples when appropriate
    - When showing code, prioritize readability and best practices
    - If you're uncertain about something, acknowledge it rather than guessing
    - When explaining concepts, use clear structure with headings and lists

    Remember that you're responding within a Neovim buffer, so your Markdown formatting will be rendered properly.
    Focus on providing actionable solutions that the developer can implement immediately.
  ]],
	mappings = {
		send_prompt = "<C-l>",
		close_window = "q",
		toggle_window = "<leader>llm",
	},
}

local win_width
local win_height
local win_row
local win_col

local function get_visual_selection()
	local _, srow, scol = unpack(vim.fn.getpos("v"))
	local _, erow, ecol = unpack(vim.fn.getpos("."))
	local mode = vim.fn.mode()

	if mode == "V" then
		local start, stop = srow > erow and erow - 1 or srow - 1, srow > erow and srow or erow
		return vim.api.nvim_buf_get_lines(0, start, stop, true)
	end

	if mode == "v" then
		if srow > erow or (srow == erow and scol > ecol) then
			srow, erow, scol, ecol = erow, srow, ecol, scol
		end
		return vim.api.nvim_buf_get_text(0, srow - 1, scol - 1, erow - 1, ecol, {})
	end

	if mode == "\22" then
		if srow > erow then
			srow, erow = erow, srow
		end
		if scol > ecol then
			scol, ecol = ecol, scol
		end
		local lines = {}
		for i = srow, erow do
			table.insert(lines, vim.api.nvim_buf_get_text(0, i - 1, scol - 1, i - 1, ecol, {})[1])
		end
		return lines
	end
end

---@param str string
local function write_to_buffer(str)
	vim.schedule(function()
		local lines = vim.split(str, "\n")
		local last_line = vim.api.nvim_buf_line_count(0)

		local last_line_content = vim.api.nvim_buf_get_lines(0, last_line - 1, last_line, false)[1]

		local new_lines = { last_line_content .. lines[1] }

		for i = 2, #lines do
			table.insert(new_lines, lines[i])
		end

		vim.cmd("undojoin")

		vim.api.nvim_buf_set_lines(0, last_line - 1, last_line, false, new_lines)

		local new_last_line = vim.api.nvim_buf_line_count(0)
		vim.api.nvim_win_set_cursor(0, { new_last_line, 0 })
	end)
end

function M.close_window()
	if llm_win and vim.api.nvim_win_is_valid(llm_win) then
		vim.api.nvim_win_close(llm_win, true)
		llm_win = nil
	end
end

---@return number buf
---@return number win
local function create_floating_window()
	local buf = vim.api.nvim_create_buf(false, true)

	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].buflisted = false
	vim.bo[buf].swapfile = false
	vim.bo[buf].modifiable = true
	vim.bo[buf].filetype = "markdown"

	vim.api.nvim_set_hl(0, "FloatTitle", {
		fg = "Orange", -- Change text color (white here)
		bg = "#31353f", -- Change background color (dark gray here)
	})

	local win = vim.api.nvim_open_win(buf, true, M.win_opts)

	vim.wo[win].wrap = true

	llm_buf = buf
	llm_win = win

	vim.api.nvim_buf_set_keymap(
		buf,
		"n",
		M.config.mappings.send_prompt,
		[[<cmd>lua require('llm-buffer').send_prompt()<CR>]],
		{
			noremap = true,
			silent = true,
		}
	)
	vim.api.nvim_buf_set_keymap(
		buf,
		"v",
		M.config.mappings.send_prompt,
		[[<cmd>lua require('llm-buffer').send_prompt()<CR>]],
		{
			noremap = true,
			silent = true,
		}
	)
	vim.api.nvim_buf_set_keymap(
		buf,
		"n",
		M.config.mappings.close_window,
		[[<cmd>lua require('llm-buffer').close_window()<CR>]],
		{
			noremap = true,
			silent = true,
		}
	)

	return buf, win
end

---@param args table # The arguments to pass to curl
---@param handle_fn function # The function to handle the response
local function make_api_request(args, handle_fn)
	local function handle_error(err)
		vim.notify("API Error: " .. (err or "Unknown error"), vim.log.levels.ERROR)
		active_job = nil
		was_cancelled = false
	end

	-- Handle any unexpected errors when making the API request
	pcall(function()
		if active_job then
			active_job:shutdown()
			active_job = nil
		end

		active_job = Job:new({
			command = "curl",
			args = args,
			on_start = function()
				vim.notify("LLM Request Started - " .. M.config.provider, vim.log.levels.DEBUG)
			end,
			on_stdout = function(_, out)
				handle_fn(out)
			end,
			on_stderr = function(_, _) end,
			on_exit = function(j, code)
				-- Check if the job result was valid JSON and if it contains an error message
				local success, json = pcall(vim.json.decode, table.concat(j:result(), "\n"))
				if success and json.error then
					if json.error.message then
						vim.notify("API Error: " .. json.error.message, vim.log.levels.ERROR)
					else
						vim.notify("API Error: " .. json.error, vim.log.levels.ERROR)
					end
					active_job = nil
					was_cancelled = false
					return
				end

				-- If the job was cancelled, don't log anything
				if was_cancelled == false then
					if code ~= 0 then
						vim.notify("LLM Request Failed", vim.log.levels.ERROR)
					else
						vim.notify("LLM Request Completed", vim.log.levels.INFO)

						-- Add a new line after the response and place cursor there
						vim.schedule(function()
							if llm_buf and vim.api.nvim_buf_is_valid(llm_buf) then
								local last_line = vim.api.nvim_buf_line_count(llm_buf)
								local last_line_content =
									vim.api.nvim_buf_get_lines(llm_buf, last_line - 1, last_line, false)[1]

								if last_line_content and #last_line_content > 0 then
									vim.api.nvim_buf_set_lines(llm_buf, last_line, last_line, false, { "", "" })
									vim.api.nvim_win_set_cursor(0, { last_line + 2, 0 })
								end
							end
						end)
					end
				else
					vim.notify("LLM Request Cancelled", vim.log.levels.INFO)
				end
				active_job = nil
				was_cancelled = false
			end,
		})

		active_job:start()

		-- Cancel the job if the user closes the window
		vim.api.nvim_create_autocmd("BufLeave", {
			buffer = llm_buf,
			callback = function()
				if active_job then
					was_cancelled = true
					active_job:shutdown()
					active_job = nil
				end
			end,
		})

		-- Cancel the job if the user presses <Esc> in any mode
		local modes = { "n", "i", "v", "x" }
		for _, mode in ipairs(modes) do
			vim.keymap.set(mode, "<Esc>", function()
				if active_job then
					was_cancelled = true
					active_job:shutdown()
					active_job = nil
				end
				-- Exit insert mode if we're in it
				if mode == "i" then
					vim.cmd("stopinsert")
				end
				-- Clear visual selection if in visual mode
				if mode == "v" or mode == "x" then
					vim.cmd("normal! <Esc>")
				end
			end, {
				buffer = llm_buf,
				noremap = true,
				silent = true,
			})
		end
	end, handle_error)
end

---@param text string
---@return number
local function estimate_token_count(text)
	return math.ceil(#text / 4)
end

---@return string
local function build_context_from_history()
	if #conversation_history == 0 then
		return ""
	end

	local start_idx = math.max(1, #conversation_history - MAX_HISTORY_MESSAGES + 1)
	local context = "<previous_context>\n"

	for i = start_idx, #conversation_history do
		local entry = conversation_history[i]
		if entry.role == "prompt" then
			context = context .. "<prompt>\n" .. entry.content .. "\n</prompt>\n\n"
		elseif entry.role == "response" then
			context = context .. "<response>\n" .. entry.content .. "\n</response>\n\n"
		end
	end
	context = context .. "</previous_context>\n\n"

	return context
end

---@param prompt string
---@param collect_fn function Function to collect the response
local function stream_openai_response(prompt, collect_fn)
	if not M.config.openai_api_key then
		vim.notify("OpenAI API key not set.", vim.log.levels.ERROR)
		return
	end

	local context = build_context_from_history()

	local body = {
		model = M.config.model,
		messages = {
			{
				role = "system",
				content = M.config.system_prompt,
			},
			{
				role = "user",
				content = context .. prompt,
			},
		},
		max_tokens = 2000,
		stream = true,
	}

	local args = {
		"-N",
		"-X",
		"POST",
		"-H",
		"Content-Type: application/json",
		"-H",
		"Authorization: Bearer " .. M.config.openai_api_key,
		"-d",
		vim.fn.json_encode(body),
		"https://api.openai.com/v1/chat/completions",
	}

	local function parse_response(line)
		if line:match("^data: %[DONE%]$") then
			return
		end

		local data = line:match("^data: (.+)$")
		if data then
			local success, json = pcall(vim.json.decode, data)
			if success and json.choices and json.choices[1].delta and json.choices[1].delta.content then
				collect_fn(json.choices[1].delta.content)
			end
		end
	end

	make_api_request(args, parse_response)
end

---@param prompt string
---@param collect_fn function Function to collect the response
local function stream_anthropic_response(prompt, collect_fn)
	if not M.config.anthropic_api_key then
		vim.notify("Anthropic API key not set.", vim.log.levels.ERROR)
		return
	end

	local context = build_context_from_history()

	local body = {
		system = M.config.system_prompt,
		messages = { {
			role = "user",
			content = context .. prompt,
		} },
		model = M.config.model,
		max_tokens = 2000,
		stream = true,
	}

	local args = {
		"-N",
		"-X",
		"POST",
		"-H",
		"Content-Type: application/json",
		"-H",
		"x-api-key: " .. M.config.anthropic_api_key,
		"-H",
		"anthropic-version: 2023-06-01",
		"-d",
		vim.fn.json_encode(body),
		"https://api.anthropic.com/v1/messages",
	}

	local c_event = nil
	local function parse_response(line)
		local event = line:match("^event: (.+)$")
		if event then
			c_event = event
			return
		end
		local data = line:match("^data: (.+)$")
		if data then
			if c_event == "content_block_delta" then
				local success, json = pcall(vim.json.decode, data)
				if success and json.delta and json.delta.text then
					collect_fn(json.delta.text)
				end
			end
		end
	end

	make_api_request(args, parse_response)
end

---@param prompt string
---@param collect_fn function Function to collect the response
local function stream_gemini_response(prompt, collect_fn)
	if not M.config.gemini_api_key then
		vim.notify("Gemini API key not set.", vim.log.levels.ERROR)
		return
	end

	local context = build_context_from_history()

	local body = {
		contents = {
			parts = {
				text = "This are your instructions: "
					.. M.config.system_prompt
					.. "\n And this is the user prompt: "
					.. context
					.. prompt,
			},
		},
	}

	-- Make the request
	local args = {
		"-N",
		"-X",
		"POST",
		"-H",
		"Content-Type: application/json",
		"-d",
		vim.fn.json_encode(body),
		"https://generativelanguage.googleapis.com/v1beta/models/"
			.. M.config.model
			.. ":streamGenerateContent?alt=sse&key="
			.. M.config.gemini_api_key,
	}

	local function parse_response(line)
		local data = line:match("^data: (.+)$")
		if data then
			local success, json = pcall(vim.json.decode, data)
			if success and json.candidates and json.candidates[1] and json.candidates[1].content then
				collect_fn(json.candidates[1].content.parts[1].text)
			end
		end
	end

	make_api_request(args, parse_response)
end

---@param prompt string
---@param collect_fn function Function to collect the response
local function stream_ollama_response(prompt, collect_fn)
	-- Build the context from conversation history
	local context = build_context_from_history()

	-- Create request body
	local body = {
		model = M.config.model,
		prompt = context .. prompt,
		system = M.config.system_prompt,
		stream = true,
	}

	-- Make the request
	local args = {
		"-N",
		"-X",
		"POST",
		"-H",
		"Content-Type: application/json",
		"-d",
		vim.fn.json_encode(body),
		M.config.ollama_api_host .. "/api/generate",
	}

	-- Parse response
	local function parse_response(line)
		local success, json = pcall(vim.json.decode, line)
		if success and json and json.response then
			collect_fn(json.response)
		end
	end

	make_api_request(args, parse_response)
end

function M.toggle_window()
	if not llm_buf or not vim.api.nvim_buf_is_valid(llm_buf) then
		local lines = get_visual_selection()
		create_floating_window()
		if lines then
			write_to_buffer(table.concat(lines, "\n"))
		end
		return
	end

	if llm_buf and llm_win and vim.api.nvim_buf_is_valid(llm_buf) then
		vim.api.nvim_win_close(llm_win, true)
		llm_win = nil
	else
		local lines = get_visual_selection()

		llm_win = vim.api.nvim_open_win(llm_buf, true, M.win_opts)
		vim.wo[llm_win].wrap = true
		vim.wo[llm_win].cursorline = true

		if lines then
			local last_line = vim.api.nvim_buf_line_count(0)
			local last_line_length = #vim.api.nvim_buf_get_lines(0, last_line - 1, last_line, false)[1]
			vim.api.nvim_win_set_cursor(0, { last_line, last_line_length })

			write_to_buffer("\n")
			write_to_buffer(table.concat(lines, "\n"))
		end
	end
end

function M.send_prompt()
	local prompt

	local lines = get_visual_selection()

	if lines then
		prompt = table.concat(lines, "\n")
	else
		prompt = vim.api.nvim_get_current_line()
	end

	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)

	local success, err = pcall(function()
		if prompt and prompt ~= "" then
			table.insert(conversation_history, {
				role = "prompt",
				content = prompt,
			})

			local current_response_index = #conversation_history + 1
			conversation_history[current_response_index] = {
				role = "response",
				content = "",
			}

			local context = build_context_from_history()
			local system_tokens = estimate_token_count(M.config.system_prompt)
			local context_tokens = estimate_token_count(context)
			local prompt_tokens = estimate_token_count(prompt)
			local total_tokens = system_tokens + context_tokens + prompt_tokens

			vim.notify(
				string.format(
					"Estimated tokens: ~%d (system: %d, context: %d, prompt: %d)",
					total_tokens,
					system_tokens,
					context_tokens,
					prompt_tokens
				),
				vim.log.levels.INFO
			)

			vim.schedule(function()
				local buf = vim.api.nvim_get_current_buf()

				local last_line = vim.api.nvim_buf_line_count(buf)

				local last_line_content = vim.api.nvim_buf_get_lines(buf, last_line - 1, last_line, false)[1]

				if last_line_content and #last_line_content > 0 then
					vim.api.nvim_buf_set_lines(buf, last_line, last_line, false, { "", "" })
					last_line = last_line + 2
				else
					vim.api.nvim_buf_set_lines(buf, last_line, last_line, false, { "" })
					last_line = last_line + 1
				end

				vim.api.nvim_win_set_cursor(0, { last_line, 0 })
			end)

			local response_collector = ""
			local function collect_response(text)
				if text and #text > 0 then
					response_collector = response_collector .. text
					conversation_history[current_response_index].content = response_collector
					write_to_buffer(text)
				end
			end

			if M.config.provider == "anthropic" then
				stream_anthropic_response(prompt, collect_response)
			elseif M.config.provider == "openai" then
				stream_openai_response(prompt, collect_response)
			elseif M.config.provider == "gemini" then
				stream_gemini_response(prompt, collect_response)
			elseif M.config.provider == "ollama" then
				stream_ollama_response(prompt, collect_response)
			end
		else
			vim.notify("No prompt found. Ensure you have a valid selection or line selected.", vim.log.levels.ERROR)
		end
	end)

	if not success then
		vim.notify("Error processing request: " .. tostring(err), vim.log.levels.ERROR)
	end
end

---@param opts? LLMBufferConfig
function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.defaults, opts or {})

	win_width = math.floor(vim.o.columns * M.config.window_width)
	win_height = math.floor(vim.o.lines * M.config.window_height)
	win_row = math.floor((vim.o.lines - win_height) / 2)
	win_col = math.floor((vim.o.columns - win_width) / 2)

	M.win_opts = {
		relative = "editor",
		style = "minimal",
		title = "  llm-buffer.nvim  ",
		title_pos = "center",
		footer = "  " .. M.config.provider .. "/" .. M.config.model .. "  ",
		footer_pos = "center",
		row = win_row,
		col = win_col,
		width = win_width,
		height = win_height,
		border = "rounded",
	}

	vim.api.nvim_create_user_command("LLMBuffer", function()
		M.toggle_window()
	end, {})

	vim.keymap.set({ "n", "v" }, M.config.mappings.toggle_window, function()
		M.toggle_window()
	end, {
		noremap = true,
		silent = true,
		desc = "Toggle LLM Buffer",
	})

	vim.api.nvim_create_autocmd("VimLeavePre", {
		callback = function()
			if llm_buf and vim.api.nvim_buf_is_valid(llm_buf) then
				vim.api.nvim_buf_delete(llm_buf, {
					force = true,
				})
			end
		end,
	})
end

---@param opts? LLMBufferConfig
function M.update_options(opts)
	if opts then
		M.config = vim.tbl_deep_extend("force", M.defaults, opts)

		M.win_opts = vim.tbl_deep_extend("force", M.win_opts, {
			footer = "  " .. M.config.provider .. "/" .. M.config.model .. "  ",
		})

		if llm_win and vim.api.nvim_win_is_valid(llm_win) then
			vim.api.nvim_win_set_config(llm_win, {
				footer = "  " .. M.config.provider .. "/" .. M.config.model .. "  ",
				footer_pos = "center",
			})
		end

		vim.notify("LLMBuffer Provider updated: " .. M.config.provider, vim.log.levels.INFO)
	end
end

return M
