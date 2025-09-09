local Prowl = {}
local M = {}

-- State management
M.state = {}
M._setup = false

-- Cache for performance
M.cache = {
  tabline = nil,
  generation = 0,
  window_width = nil,
  last_buf = nil,
  last_modified = nil,
}

M.buffer_cache = {}

-- Lookup tables for O(1) access
M.label_lookup = {}
M.filename_lookup = {}

-- Preallocated tables to reduce garbage collection
M.preallocated = {
  items = {},
  result = {},
}

-- Constants
local CONSTANTS = {
  MIN_TABLINE_WIDTH = 20,
  TRUNCATION_INDICATOR_WIDTH = 3,
  FALLBACK_PRIORITY = 999,
}

-- Default configuration
M.config = {
  -- Labels for quick buffer jumping (these ARE the keyboard keys you press)
  labels = { "q", "w", "e", "r", "a", "s", "d", "f", "c", "v", "t", "g", "b", "z", "x" },

  cycle_wraps_around = true,
  show_modified_indicator = true,
  max_filename_length = 20,

  mappings = {
    jump = ";",
    next = "<S-l>",
    prev = "<S-h>",
  },

  highlights = {
    bar = { fg = "#ffffff", bg = "#1f2335" },

    active_tab = { fg = "#ffffff", bg = "#1f2335" },
    active_label = { fg = "#ff9e64", bg = "#1f2335", bold = false },
    active_tab_modified = { fg = "#ffffff", bg = "#1f2335" },
    active_label_modified = { fg = "#ff9e64", bg = "#1f2335", bold = false },

    inactive_tab = { fg = "#828BB8", bg = "#1f2335" },
    inactive_label = { fg = "#ff9e64", bg = "#1f2335", bold = false },
    inactive_tab_modified = { fg = "#828BB8", bg = "#1f2335" },
    inactive_label_modified = { fg = "#ff9e64", bg = "#1f2335", bold = false },

    truncation = { fg = "#ff9e64", bg = "#1f2335" },
  },
}

-- Cache invalidation
M.invalidate_tabline = function()
  M.cache.generation = M.cache.generation + 1
  M.cache.tabline = nil
end

M.rebuild_lookups = function()
  M.label_lookup = {}
  M.filename_lookup = {}

  for _, item in ipairs(M.state) do
    if item.label then
      M.label_lookup[item.label] = item
    end
    M.filename_lookup[item.filename] = item
  end
end

-- Validation
local function validate_config(config)
  if not config then
    return true
  end

  if config.labels then
    if type(config.labels) ~= "table" then
      vim.notify("Prowl: labels must be an array", vim.log.levels.ERROR)
      return false
    end
    for _, label in ipairs(config.labels) do
      if type(label) ~= "string" or #label ~= 1 then
        vim.notify("Prowl: labels must be single characters", vim.log.levels.ERROR)
        return false
      end
    end
  end

  return true
end

-- Setup
Prowl.setup = function(user_config)
  if M._setup then
    vim.notify("Prowl: Already initialized", vim.log.levels.WARN)
    return
  end

  if not validate_config(user_config) then
    return
  end

  M.config = vim.tbl_deep_extend("force", M.config, user_config or {})

  if #M.config.labels == 0 then
    vim.notify("Prowl: labels cannot be empty", vim.log.levels.ERROR)
    return
  end

  M.apply_config()
  M.create_autocommands()
  M.create_highlights()

  M._setup = true
  _G.Prowl = Prowl
end

-- Configuration
M.apply_config = function()
  -- Build label priority lookup (position in list = priority)
  M.label_priority = {}
  for i, label in ipairs(M.config.labels) do
    M.label_priority[label] = i
  end

  vim.opt.showtabline = 2
  vim.opt.tabline = "%!v:lua.Prowl.gen_tabline()"

  M.setup_keymaps()
end

-- Keymaps
M.setup_keymaps = function()
  local function safe_map(mode, lhs, rhs, opts)
    if not lhs or lhs == "" then
      return
    end
    opts = vim.tbl_extend("force", { silent = true, noremap = true }, opts or {})
    vim.keymap.set(mode, lhs, rhs, opts)
  end

  local mappings = M.config.mappings

  -- Single mapping that handles jump, close, and close-all-except!
  safe_map("n", mappings.jump, function()
    local char = vim.fn.getcharstr()

    -- Special commands
    if char == "!" then
      Prowl.close_all_except_current()
    elseif char:match("^%u$") then -- Uppercase letter?
      Prowl.close(char:lower())
    else
      -- Normal jump
      Prowl.jump(char)
    end
  end, { desc = "Prowl: jump to or close buffer" })

  safe_map("n", mappings.next, Prowl.next, { desc = "Prowl: next buffer" })
  safe_map("n", mappings.prev, Prowl.prev, { desc = "Prowl: prev buffer" })
end

-- Highlights
M.create_highlights = function()
  local hl_map = {
    ProwlBar = M.config.highlights.bar,
    ProwlActiveTab = M.config.highlights.active_tab,
    ProwlActiveLabel = M.config.highlights.active_label,
    ProwlActiveTabModified = M.config.highlights.active_tab_modified,
    ProwlActiveLabelModified = M.config.highlights.active_label_modified,
    ProwlInactiveTab = M.config.highlights.inactive_tab,
    ProwlInactiveLabel = M.config.highlights.inactive_label,
    ProwlInactiveTabModified = M.config.highlights.inactive_tab_modified,
    ProwlInactiveLabelModified = M.config.highlights.inactive_label_modified,
    ProwlTruncation = M.config.highlights.truncation,
  }

  for name, opts in pairs(hl_map) do
    opts.default = true
    vim.api.nvim_set_hl(0, name, opts)
  end
end

-- Autocommands
M.pending_buffers = {}
M.process_timer = nil

M.create_autocommands = function()
  local group = vim.api.nvim_create_augroup("Prowl", { clear = true })

  -- Clean up deleted buffers
  vim.api.nvim_create_autocmd("BufDelete", {
    group = group,
    desc = "Clean up Prowl state for deleted buffers",
    callback = function(args)
      local filename = vim.api.nvim_buf_get_name(args.buf)
      if filename ~= "" then
        M.remove_buffer(filename)
      end
    end,
  })

  -- Clear buffer cache on unload
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufUnload" }, {
    group = group,
    desc = "Clear Prowl buffer cache",
    callback = function(args)
      M.buffer_cache[args.buf] = nil
    end,
  })

  -- Track new buffers with batching
  vim.api.nvim_create_autocmd({ "BufWinEnter", "BufAdd" }, {
    group = group,
    desc = "Track buffer changes for Prowl",
    callback = function(args)
      local filename = vim.api.nvim_buf_get_name(args.buf)
      if filename == "" then
        return
      end

      M.pending_buffers[filename] = true

      if M.process_timer then
        M.process_timer:stop()
      end

      M.process_timer = vim.defer_fn(function()
        for fname, _ in pairs(M.pending_buffers) do
          M.add_buffer(fname)
        end
        M.pending_buffers = {}
        M.process_timer = nil
      end, 10)
    end,
  })
end

-- Buffer utilities
M.get_bufnr = function(filename)
  if not filename or filename == "" then
    return -1
  end
  return vim.fn.bufnr(filename)
end

M.is_valid_buffer = function(bufnr)
  return bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr)
end

M.should_show_buffer = function(filename)
  local bufnr = M.get_bufnr(filename)

  if not M.is_valid_buffer(bufnr) then
    M.buffer_cache[bufnr] = nil
    return false
  end

  -- Check cache first
  local cached = M.buffer_cache[bufnr]
  if cached and cached.generation == M.cache.generation then
    return cached.result
  end

  -- Check buffer properties
  local ok, result = pcall(function()
    return vim.bo[bufnr].buflisted and vim.bo[bufnr].buftype == "" and vim.api.nvim_buf_get_name(bufnr) ~= ""
  end)

  local should_show = ok and result

  -- Update cache
  M.buffer_cache[bufnr] = {
    result = should_show,
    generation = M.cache.generation,
  }

  return should_show
end

-- Check if buffer is visible in any window
M.is_buffer_visible = function(bufnr)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      return true
    end
  end
  return false
end

-- State management with clearer names
M.get_buffer_by_label = function(label)
  return M.label_lookup[label]
end

M.get_buffer_by_filename = function(filename)
  local full_filename = vim.fn.fnamemodify(filename, ":p")
  return M.filename_lookup[full_filename]
end

-- Buffer closing function
M.remove_buffer = function(filename)
  local full_filename = vim.fn.fnamemodify(filename, ":p")
  for i = #M.state, 1, -1 do
    if M.state[i].filename == full_filename then
      table.remove(M.state, i)
      M.rebuild_lookups()
      M.invalidate_tabline()
      break
    end
  end
end

-- Buffer closing function
M.close_buffer = function(label)
  local buffer_info = M.get_buffer_by_label(label)
  if buffer_info and buffer_info.filename then
    local bufnr = M.get_bufnr(buffer_info.filename)
    if M.is_valid_buffer(bufnr) then
      -- Use pcall in case buffer can't be deleted (unsaved changes, etc.)
      local ok, err = pcall(vim.api.nvim_buf_delete, bufnr, { force = false })
      if not ok then
        vim.notify("Can't close buffer: " .. vim.fn.fnamemodify(buffer_info.filename, ":t"), vim.log.levels.WARN)
      else
        -- Remove from state after successful close
        M.remove_buffer(buffer_info.filename)
      end
    end
  end
end

M.close_all_except_current = function()
  local current_buf = vim.api.nvim_get_current_buf()
  local current_filename = vim.api.nvim_buf_get_name(current_buf)
  local closed_count = 0
  local failed_count = 0
  local skipped_visible = 0

  -- Store buffers that should remain
  local keep_buffers = {}

  -- Close all buffers except current AND visible ones
  for i = #M.state, 1, -1 do
    local item = M.state[i]
    local bufnr = M.get_bufnr(item.filename)

    if bufnr ~= current_buf and M.is_valid_buffer(bufnr) then
      -- Check if buffer is visible in any window
      if M.is_buffer_visible(bufnr) then
        skipped_visible = skipped_visible + 1
        table.insert(keep_buffers, item)
      else
        local ok = pcall(vim.api.nvim_buf_delete, bufnr, { force = false })
        if ok then
          closed_count = closed_count + 1
        else
          failed_count = failed_count + 1
          table.insert(keep_buffers, item) -- Keep buffers that failed to close
        end
      end
    elseif bufnr == current_buf then
      table.insert(keep_buffers, item)
    end
  end

  -- Rebuild state with kept buffers
  M.state = keep_buffers

  -- Sort to maintain label order
  M.sort_buffers()

  -- Force a tabline refresh
  M.invalidate_tabline()
  vim.cmd("redrawtabline")

  -- Give feedback
  local msg = string.format("Closed %d buffer%s", closed_count, closed_count == 1 and "" or "s")
  if failed_count > 0 then
    msg = msg .. string.format(" (%d failed - unsaved changes)", failed_count)
  end
  if skipped_visible > 0 then
    msg = msg .. string.format(" (%d visible in windows)", skipped_visible)
  end
  vim.notify(msg, vim.log.levels.INFO)
end

M.sort_buffers = function()
  -- Sort by label priority (lower number = higher priority)
  table.sort(M.state, function(a, b)
    local priority_a = M.label_priority[a.label] or CONSTANTS.FALLBACK_PRIORITY
    local priority_b = M.label_priority[b.label] or CONSTANTS.FALLBACK_PRIORITY
    return priority_a < priority_b
  end)
  M.rebuild_lookups()
  M.invalidate_tabline()
end

-- Add buffer to state - new buffers appear on the right
M.add_buffer = function(filename)
  local full_filename = vim.fn.fnamemodify(filename, ":p")

  -- Skip if already tracked or shouldn't be shown
  if M.get_buffer_by_filename(full_filename) or not M.should_show_buffer(full_filename) then
    return
  end

  local labels = M.config.labels

  -- Find ANY available label (prefer earlier ones for efficiency)
  local available_label = nil
  for _, label in ipairs(labels) do
    if not M.get_buffer_by_label(label) then
      available_label = label
      break
    end
  end

  if available_label then
    -- Add new buffer at the END of the state array (rightmost position)
    table.insert(M.state, {
      label = available_label,
      filename = full_filename,
    })
    M.rebuild_lookups()
    M.invalidate_tabline()
  else
    -- All labels taken - shift everything left and add new one at the end
    for i = 1, #labels - 1 do
      local current = M.get_buffer_by_label(labels[i])
      local next = M.get_buffer_by_label(labels[i + 1])
      if current and next then
        current.filename = next.filename
      end
    end

    -- New buffer gets the last label
    local last = M.get_buffer_by_label(labels[#labels])
    if last then
      last.filename = full_filename
    end

    M.rebuild_lookups()
    M.invalidate_tabline()
  end
end

-- Buffer cycling
M.cycle_buffers = function(direction)
  if #M.state == 0 then
    return
  end

  local current_buf = vim.api.nvim_get_current_buf()
  local current_index = nil

  -- Find current buffer index
  for i, item in ipairs(M.state) do
    if current_buf == M.get_bufnr(item.filename) then
      current_index = i
      break
    end
  end

  -- If current buffer not in state, jump to first
  if not current_index then
    local first_item = M.state[1]
    if first_item then
      vim.api.nvim_set_current_buf(M.get_bufnr(first_item.filename))
    end
    return
  end

  -- Calculate next index
  local next_index = current_index + direction

  if M.config.cycle_wraps_around then
    next_index = ((next_index - 1) % #M.state) + 1
  else
    if next_index < 1 or next_index > #M.state then
      return
    end
  end

  -- Jump to next buffer
  local next_item = M.state[next_index]
  if next_item then
    local bufnr = M.get_bufnr(next_item.filename)
    if M.is_valid_buffer(bufnr) then
      vim.api.nvim_set_current_buf(bufnr)
      M.invalidate_tabline()
    end
  end
end

-- Tabline generation helpers
M.get_tabpage_info = function()
  local n_tabpages = vim.fn.tabpagenr("$")
  if n_tabpages == 1 then
    return ""
  end
  return string.format("%%= Tab %d/%d ", vim.fn.tabpagenr(), n_tabpages)
end

M.format_filename = function(filename)
  local name = vim.fn.fnamemodify(filename, ":t")
  if name == "" then
    return "[No Name]"
  end

  -- Truncate long filenames
  local max_len = M.config.max_filename_length
  if max_len and #name > max_len then
    name = name:sub(1, max_len - 3) .. "..."
  end

  return name
end

-- Generate a single tabline item
M.create_tabline_item = function(buffer_info, current_buf, bufnr, output_table, index)
  local is_current = bufnr == current_buf

  -- Reuse table if it exists
  local item = output_table[index] or {}

  -- Check modified state only if we're showing the indicator
  local is_modified = false
  if M.config.show_modified_indicator then
    local ok, modified = pcall(function()
      return vim.bo[bufnr].modified
    end)
    is_modified = ok and modified
  end

  local filename = M.format_filename(buffer_info.filename)
  local mod_suffix = is_modified and "Modified" or ""
  local mod_indicator = (is_modified and M.config.show_modified_indicator) and "+" or ""

  -- Update item properties
  item.bufnr = bufnr
  item.hl_label = (is_current and "ProwlActiveLabel" or "ProwlInactiveLabel") .. mod_suffix
  item.label = buffer_info.label and (buffer_info.label .. " ") or ""
  item.hl_tab = (is_current and "ProwlActiveTab" or "ProwlInactiveTab") .. mod_suffix
  item.content = filename .. mod_indicator

  output_table[index] = item
  return item
end

M.format_tabline_item = function(item)
  return string.format("%%#%s# %s%%#%s#%s ", item.hl_label, item.label, item.hl_tab, item.content)
end

M.calculate_item_width = function(item)
  return vim.api.nvim_strwidth(string.format(" %s %s ", item.label, item.content))
end

-- Truncate tabline to fit window width
M.truncate_tabline = function(items, center_index, available_width)
  if #items == 0 or available_width < CONSTANTS.MIN_TABLINE_WIDTH then
    return ""
  end

  -- Clear and reuse result table
  for i = #M.preallocated.result, 1, -1 do
    M.preallocated.result[i] = nil
  end

  -- Start with center item (current buffer)
  M.preallocated.result[1] = items[center_index]
  local left_idx = center_index - 1
  local right_idx = center_index + 1
  local truncated_left = false
  local truncated_right = false

  -- Track total width to avoid recalculation
  local total_width = M.calculate_item_width(items[center_index])

  -- Add items from both sides until we run out of space
  while
    (left_idx >= 1 or right_idx <= #items) and total_width < available_width - CONSTANTS.TRUNCATION_INDICATOR_WIDTH
  do
    local added = false

    -- Try adding from left
    if left_idx >= 1 then
      local item_width = M.calculate_item_width(items[left_idx])
      if total_width + item_width <= available_width - CONSTANTS.TRUNCATION_INDICATOR_WIDTH then
        table.insert(M.preallocated.result, 1, items[left_idx])
        total_width = total_width + item_width
        left_idx = left_idx - 1
        added = true
      else
        truncated_left = true
      end
    end

    -- Try adding from right
    if right_idx <= #items and total_width < available_width - CONSTANTS.TRUNCATION_INDICATOR_WIDTH then
      local item_width = M.calculate_item_width(items[right_idx])
      if total_width + item_width <= available_width - CONSTANTS.TRUNCATION_INDICATOR_WIDTH then
        table.insert(M.preallocated.result, items[right_idx])
        total_width = total_width + item_width
        right_idx = right_idx + 1
        added = true
      else
        truncated_right = true
      end
    end

    if not added then
      break
    end
  end

  -- Build final string
  local parts = {}
  local n = 0

  if truncated_left then
    n = n + 1
    parts[n] = "%#ProwlTruncation# < "
  end

  for _, item in ipairs(M.preallocated.result) do
    n = n + 1
    parts[n] = M.format_tabline_item(item)
  end

  if truncated_right then
    n = n + 1
    parts[n] = "%#ProwlTruncation# > "
  end

  return table.concat(parts)
end

-- Public API
Prowl.state = function()
  return vim.deepcopy(M.state)
end

Prowl.jump = function(label)
  if not label or label == "" then
    return
  end

  local buffer_info = M.get_buffer_by_label(label)
  if buffer_info and buffer_info.filename then
    local bufnr = M.get_bufnr(buffer_info.filename)
    if M.is_valid_buffer(bufnr) then
      vim.api.nvim_set_current_buf(bufnr)
      M.invalidate_tabline()
    end
  end
end

Prowl.next = function()
  M.cycle_buffers(1) -- Positive direction = move right
end

Prowl.prev = function()
  M.cycle_buffers(-1) -- Negative direction = move left
end

Prowl.close = function(label)
  M.close_buffer(label)
end

Prowl.close_all_except_current = function()
  M.close_all_except_current()
end

-- Main tabline generation (with caching)
Prowl.gen_tabline = function()
  local current_width = vim.o.columns
  local current_buf = vim.api.nvim_get_current_buf()

  -- Try to use cached tabline
  if M.cache.tabline and M.cache.window_width == current_width and M.cache.last_buf == current_buf then
    -- Check if modified state changed
    local ok, modified = pcall(function()
      return vim.bo[current_buf].modified
    end)
    if ok and M.cache.last_modified == modified then
      return M.cache.tabline
    end
  end

  -- Clear items table for reuse
  for i = #M.preallocated.items, 1, -1 do
    M.preallocated.items[i] = nil
  end

  local center_index = 1
  local item_count = 0

  -- Build list of visible items
  for i = 1, #M.state do
    local buffer_info = M.state[i]
    if M.should_show_buffer(buffer_info.filename) then
      local bufnr = M.get_bufnr(buffer_info.filename)
      item_count = item_count + 1
      if bufnr == current_buf then
        center_index = item_count
      end
      M.create_tabline_item(buffer_info, current_buf, bufnr, M.preallocated.items, item_count)
    else
      -- Remove buffers that shouldn't be shown anymore
      M.remove_buffer(buffer_info.filename)
    end
  end

  -- Generate final tabline
  local result
  if item_count == 0 then
    result = "%X%#ProwlBar#" .. M.get_tabpage_info()
  else
    local available_width = current_width - vim.api.nvim_strwidth(M.get_tabpage_info())
    local truncated = M.truncate_tabline(M.preallocated.items, center_index, available_width)
    result = truncated .. "%X%#ProwlBar#" .. M.get_tabpage_info()
  end

  -- Update cache
  M.cache.tabline = result
  M.cache.window_width = current_width
  M.cache.last_buf = current_buf
  local ok, modified = pcall(function()
    return vim.bo[current_buf].modified
  end)
  M.cache.last_modified = ok and modified

  return result
end

-- Utility functions
Prowl.get_config = function()
  return vim.deepcopy(M.config)
end

Prowl.refresh = function()
  M.invalidate_tabline()
  vim.cmd("redrawtabline")
end

-- Debug helper
Prowl.debug = function()
  print("Current state:")
  for i, item in ipairs(M.state) do
    print(string.format("  %d. [%s] %s", i, item.label, vim.fn.fnamemodify(item.filename, ":t")))
  end
end

return Prowl
