local M = {}

M.config = {
	keymap_review = "<leader>gR",
	keymap_copy_path = "<leader>yL",
	keymap_add_comment = "<leader>grc",
	keymap_show_comments = "<leader>grs",
	keymap_yank_comments = "<leader>gry",
	keymap_clear_comments = "<leader>grx",
}

-- Store comments in memory
M.comments = {}

function M.copy_path_with_line()
	local path = vim.fn.expand("%:.")
	local result

	if vim.fn.mode() == "n" then
		result = path .. "#L" .. vim.fn.line(".")
	else
		local start_line = vim.fn.line("v")
		local end_line = vim.fn.line(".")
		if start_line > end_line then
			start_line, end_line = end_line, start_line
		end
		result = path .. "#L" .. start_line .. "-L" .. end_line
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
	end

	vim.fn.setreg("+", result)
	vim.notify("Copied: " .. result)
end

function M.review()
	local diff_output = vim.fn.systemlist("git diff HEAD")

	if #diff_output == 0 then
		vim.notify("No uncommitted changes")
		return
	end

	local sha = vim.fn.systemlist("git rev-parse --short HEAD")[1]
	local timestamp = os.time()
	local buffer_name = string.format("review_%s_dirty_%d.md", sha, timestamp)

	-- Parse diff into hunks
	local hunks = {}
	local current_file = ""
	local hunk_lines = {}
	local hunk_header = ""

	local function flush_hunk()
		if #hunk_lines > 0 then
			table.insert(hunks, {
				file = current_file,
				header = hunk_header,
				content = table.concat(hunk_lines, "\n"),
			})
			hunk_lines = {}
		end
	end

	for _, line in ipairs(diff_output) do
		if line:match("^diff %-%-git") then
			flush_hunk()
		elseif line:match("^%+%+%+ b/") then
			current_file = line:sub(7)
		elseif line:match("^@@") then
			flush_hunk()
			hunk_header = line:match("^(@@ .* @@)")
		elseif
			current_file ~= ""
			and not line:match("^index ")
			and not line:match("^%-%-%-")
			and not line:match("^%+%+%+")
		then
			table.insert(hunk_lines, line)
		end
	end
	flush_hunk()

	-- Build output
	local lines = {}
	for _, hunk in ipairs(hunks) do
		table.insert(lines, "### " .. hunk.file .. " " .. hunk.header)
		table.insert(lines, "")
		table.insert(lines, "```diff")
		for diff_line in hunk.content:gmatch("[^\n]+") do
			table.insert(lines, diff_line)
		end
		table.insert(lines, "```")
		table.insert(lines, "")
		table.insert(lines, "**Comments:**")
		table.insert(lines, "")
		table.insert(lines, "")
	end

	-- If in a special buffer (like NeoTree), go to previous window first
	if vim.bo.buftype ~= "" then
		vim.cmd("wincmd p")
	end

	vim.cmd("enew")
	local buf = vim.api.nvim_get_current_buf()
	vim.bo[buf].filetype = "markdown"
	vim.wo.foldenable = false
	vim.api.nvim_buf_set_name(buf, buffer_name)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

	vim.notify("Review: " .. buffer_name)
end

-- Add a comment at the current line (or visual selection)
function M.add_comment()
	local file = vim.fn.expand("%:.")
	local snippet
	local start_line, end_line

	if vim.fn.mode() == "n" then
		start_line = vim.fn.line(".")
		end_line = start_line
		snippet = vim.fn.getline(".")
	else
		start_line = vim.fn.line("v")
		end_line = vim.fn.line(".")
		if start_line > end_line then
			start_line, end_line = end_line, start_line
		end
		snippet = table.concat(vim.fn.getline(start_line, end_line), "\n")
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
	end

	local comment = vim.fn.input("Comment: ")
	if comment ~= "" then
		table.insert(M.comments, {
			file = file,
			start_line = start_line,
			end_line = end_line,
			snippet = snippet,
			comment = comment,
		})
		vim.notify(string.format("Comment added: %s:%d", file, start_line))
	end
end

-- Show all comments in a scratch buffer
function M.show_comments()
	if #M.comments == 0 then
		vim.notify("No comments yet")
		return
	end

	local lines = { "## Review Comments", "" }
	for _, c in ipairs(M.comments) do
		local location
		if c.start_line == c.end_line then
			location = string.format("**%s:%d**", c.file, c.start_line)
		else
			location = string.format("**%s:%d-%d**", c.file, c.start_line, c.end_line)
		end
		table.insert(lines, location)
		table.insert(lines, "```")
		for snippet_line in c.snippet:gmatch("[^\n]+") do
			table.insert(lines, snippet_line)
		end
		table.insert(lines, "```")
		table.insert(lines, "> " .. c.comment)
		table.insert(lines, "")
	end

	-- Check if buffer already exists
	local buf_name = "review-comments.md"
	local existing_buf = vim.fn.bufnr(buf_name)

	if existing_buf ~= -1 then
		-- Buffer exists, find window or open in split
		local win_id = vim.fn.bufwinid(existing_buf)
		if win_id ~= -1 then
			vim.api.nvim_set_current_win(win_id)
		else
			vim.cmd("vsplit")
			vim.api.nvim_win_set_buf(0, existing_buf)
		end
		vim.api.nvim_buf_set_lines(existing_buf, 0, -1, false, lines)
	else
		-- Create new buffer
		vim.cmd("vsplit")
		local buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.bo[buf].filetype = "markdown"
		vim.api.nvim_buf_set_name(buf, buf_name)
		vim.api.nvim_win_set_buf(0, buf)
	end
end

-- Yank all comments as markdown to clipboard
function M.yank_comments()
	if #M.comments == 0 then
		vim.notify("No comments to yank")
		return
	end

	local lines = { "## Review Comments", "" }
	for _, c in ipairs(M.comments) do
		local location
		if c.start_line == c.end_line then
			location = string.format("**%s:%d**", c.file, c.start_line)
		else
			location = string.format("**%s:%d-%d**", c.file, c.start_line, c.end_line)
		end
		table.insert(lines, location)
		table.insert(lines, "```")
		for snippet_line in c.snippet:gmatch("[^\n]+") do
			table.insert(lines, snippet_line)
		end
		table.insert(lines, "```")
		table.insert(lines, "> " .. c.comment)
		table.insert(lines, "")
	end

	local content = table.concat(lines, "\n")
	vim.fn.setreg("+", content)
	vim.notify(string.format("Yanked %d comments to clipboard", #M.comments))
end

-- Clear all comments
function M.clear_comments()
	local count = #M.comments
	M.comments = {}
	vim.notify(string.format("Cleared %d comments", count))
end

function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.config, opts or {})

	vim.keymap.set(
		{ "n", "v" },
		M.config.keymap_copy_path,
		M.copy_path_with_line,
		{ desc = "Copy file path with line number" }
	)
	vim.keymap.set("n", M.config.keymap_review, M.review, { desc = "Review local changes like a PR" })
	vim.keymap.set(
		{ "n", "v" },
		M.config.keymap_add_comment,
		M.add_comment,
		{ desc = "Add review comment at line" }
	)
	vim.keymap.set("n", M.config.keymap_show_comments, M.show_comments, { desc = "Show all review comments" })
	vim.keymap.set("n", M.config.keymap_yank_comments, M.yank_comments, { desc = "Yank comments as markdown" })
	vim.keymap.set("n", M.config.keymap_clear_comments, M.clear_comments, { desc = "Clear all comments" })
end

return M
