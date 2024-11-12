---@class LLMBufferConfig
---@field window_width? number Width of the floating window (0-1)
---@field window_height? number Height of the floating window (0-1)
---@field anthropic_api_key? string|nil API key for Anthropic
---@field ollama_api_host? string|nil API host for Ollama
---@field openai_api_key? string|nil API key for OpenAI
---@field provider? "anthropic"|"openai"|"ollama" The LLM provider to use
---@field model? string The model to use for completion
---@field system_prompt? string The system prompt to use
---@field mappings? LLMBufferMappings Key mappings configuration

---@class LLMBufferMappings
---@field send_prompt? string Keymap to send the prompt
---@field close_window? string Keymap to close the window
---@field toggle_window? string Keymap to toggle the window

local M = {}
local Job = require("plenary.job")

local active_job = nil
local llm_buf = nil
local llm_win = nil
local was_cancelled = false

-- Configuration
---@type LLMBufferConfig
M.defaults = {
	window_width = 0.85,
	window_height = 0.85,
	anthropic_api_key = os.getenv("ANTHROPIC_API_KEY"),
	openai_api_key = os.getenv("OPENAI_API_KEY"),
	ollama_api_host = "http://localhost:11434",
	provider = "anthropic", -- "anthropic" or "openai" or "ollama"
	model = "claude-3-5-sonnet-latest", -- "claude-3-5-sonnet-latest" or "claude-3-5-haiku-latest" or "gpt-4o-mini"
	system_prompt = [[
    You are a helpful assistant. You are an expert in the field of computer science and software development.
    You have a deep understanding of the topic and are able to provide accurate and helpful information.
    You currently reside inside a Markdown file buffer in neovim - use proper markdown syntax to answer the user's question. 
    Any code examples should be formatted in markdown as well.
    Be concise and to the point.
    If you don't know the answer, just say that you don't know, don't try to make up an answer.
  ]],
	mappings = {
		send_prompt = "<C-l>",
		close_window = "q",
		toggle_window = "<leader>llm",
	},
}

-- Buffer window options
local win_width
local win_height
local win_row
local win_col
local win_opts

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
		local current_window = vim.api.nvim_get_current_win()
		local cursor_position = vim.api.nvim_win_get_cursor(current_window)
		local row, col = cursor_position[1], cursor_position[2]

		local lines = vim.split(str, "\n")

		vim.cmd("undojoin")
		vim.api.nvim_put(lines, "c", true, true)

		local num_lines = #lines
		local last_line_length = #lines[num_lines]
		vim.api.nvim_win_set_cursor(current_window, { row + num_lines - 1, col + last_line_length })
	end)
end

-- Create the floating window
---@return number buf
---@return number win
local function create_floating_window()
	local buf = vim.api.nvim_create_buf(false, true)

	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].swapfile = false
	vim.bo[buf].modifiable = true
	vim.bo[buf].filetype = "markdown"

	vim.api.nvim_set_hl(0, "FloatTitle", {
		fg = "Orange", -- Change text color (white here)
		bg = "#31353f", -- Change background color (dark gray here)
	})

	local win = vim.api.nvim_open_win(buf, true, win_opts)

	-- Set window options
	vim.wo[win].wrap = true

	llm_buf = buf
	llm_win = win

	vim.api.nvim_buf_set_keymap(
		buf,
		"n",
		M.config.mappings.send_prompt,
		[[<cmd>lua require('llm-buffer').send_prompt()<CR>]],
		{ noremap = true, silent = true }
	)
	vim.api.nvim_buf_set_keymap(
		buf,
		"v",
		M.config.mappings.send_prompt,
		[[<cmd>lua require('llm-buffer').send_prompt()<CR>]],
		{ noremap = true, silent = true }
	)
	vim.api.nvim_buf_set_keymap(
		buf,
		"n",
		M.config.mappings.close_window,
		[[<cmd>lua vim.api.nvim_win_close(0, true)<CR>]],
		{ noremap = true, silent = true }
	)

	return buf, win
end

-- API Request + Job Handling
---@param args table # The arguments to pass to curl
---@param handle_fn function # The function to handle the response
local function make_api_request(args, handle_fn)
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
		end, { buffer = llm_buf, noremap = true, silent = true })
	end
end

-- Fuction to stream response from OpenAI API
---@param prompt string
local function stream_openai_response(prompt)
	-- Ensure we have an API key
	if not M.config.openai_api_key then
		vim.notify("OpenAI API key not set.", vim.log.levels.ERROR)
		return
	end

	local body = {
		model = M.config.model,
		messages = {
			{
				role = "system",
				content = M.config.system_prompt,
			},
			{
				role = "user",
				content = prompt,
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
			if success and json.choices and json.choices[1].delta.content then
				write_to_buffer(json.choices[1].delta.content)
			end
		end
	end

	make_api_request(args, parse_response)
end

-- Function to stream response from Anthropic API
---@param prompt string
local function stream_anthropic_response(prompt)
	-- Ensure we have an API key
	if not M.config.anthropic_api_key then
		vim.notify("Anthropic API key not set.", vim.log.levels.ERROR)
		return
	end

	-- Create request body
	local body = {
		system = M.config.system_prompt,
		messages = {
			{
				role = "user",
				content = prompt,
			},
		},
		model = M.config.model,
		max_tokens = 2000,
		stream = true,
	}

	-- Make the request
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

	-- Parse response
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
				local json = vim.json.decode(data)
				if json.delta and json.delta.text then
					write_to_buffer(json.delta.text)
				end
			end
		end
	end

	make_api_request(args, parse_response)
end

-- Function to stream response from Ollama API
---@param prompt string
local function stream_ollama_response(prompt)
	-- Create request body
	local body = {
		model = M.config.model,
		prompt = prompt,
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
		if success and json.response then
			write_to_buffer(json.response)
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

	local wins = vim.api.nvim_list_wins()
	local is_visible = false
	for _, win in ipairs(wins) do
		if vim.api.nvim_win_get_buf(win) == llm_buf then
			vim.api.nvim_win_close(win, true)
			is_visible = true
			break
		end
	end

	if not is_visible then
		llm_win = vim.api.nvim_open_win(llm_buf, true, win_opts)
		vim.wo[llm_win].wrap = true
		vim.wo[llm_win].cursorline = true
	end
end

function M.send_prompt()
	local prompt

	-- Get the visual selection or selected line
	local lines = get_visual_selection()

	if lines then
		prompt = table.concat(lines, "\n")
	else
		prompt = vim.api.nvim_get_current_line()
	end

	-- Exit visual mode
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)

	-- Move to the end of the buffer
	local last_line = vim.api.nvim_buf_line_count(0)
	local last_line_length = #vim.api.nvim_buf_get_lines(0, last_line - 1, last_line, false)[1]
	vim.api.nvim_win_set_cursor(0, { last_line, last_line_length })

	local success, err = pcall(function()
		if prompt and prompt ~= "" then
			write_to_buffer("\n\n")
			if M.config.provider == "anthropic" then
				stream_anthropic_response(prompt)
			elseif M.config.provider == "openai" then
				stream_openai_response(prompt)
			elseif M.config.provider == "ollama" then
				stream_ollama_response(prompt)
			end
		else
			vim.notify("No prompt found. Ensure you have a valid selection or line selected.", vim.log.levels.ERROR)
		end
	end)

	if not success then
		vim.notify("Error processing request: " .. tostring(err), vim.log.levels.ERROR)
	end
end

-- Setup function to create keymaps
---@param opts? LLMBufferConfig
function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.defaults, opts or {})

	-- Set window options
	win_width = math.floor(vim.o.columns * M.config.window_width)
	win_height = math.floor(vim.o.lines * M.config.window_height)
	win_row = math.floor((vim.o.lines - win_height) / 2)
	win_col = math.floor((vim.o.columns - win_width) / 2)

	win_opts = {
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

	-- Create the LLMBuffer command
	vim.api.nvim_create_user_command("LLMBuffer", function()
		M.toggle_window()
	end, {})

	-- Set up the global keybinding
	vim.keymap.set({ "n", "v" }, M.config.mappings.toggle_window, function()
		M.toggle_window()
	end, { noremap = true, silent = true, desc = "Toggle LLM Buffer" })

	-- If the buffer is open before exiting Neovim, close it (helps with session management)
	vim.api.nvim_create_autocmd("VimLeavePre", {
		callback = function()
			if llm_buf and vim.api.nvim_buf_is_valid(llm_buf) then
				vim.api.nvim_buf_delete(llm_buf, { force = true })
			end
		end,
	})
end

-- Function to update options during runtime
---@param opts? LLMBufferConfig
function M.update_options(opts)
	if opts then
		M.config = vim.tbl_deep_extend("force", M.defaults, opts)
		vim.notify("LLMBuffer Provider updated: " .. M.config.provider, vim.log.levels.INFO)
	end
end

return M
