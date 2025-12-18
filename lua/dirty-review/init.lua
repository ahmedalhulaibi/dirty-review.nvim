local M = {}

M.config = {
	keymap_review = "<leader>gR",
	keymap_copy_path = "<leader>yL",
}

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

function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.config, opts or {})

	vim.keymap.set(
		{ "n", "v" },
		M.config.keymap_copy_path,
		M.copy_path_with_line,
		{ desc = "Copy file path with line number" }
	)
	vim.keymap.set("n", M.config.keymap_review, M.review, { desc = "Review local changes like a PR" })
end

return M
