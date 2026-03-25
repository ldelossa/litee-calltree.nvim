local lib_state     = require("litee.lib.state")
local lib_tree      = require("litee.lib.tree")
local lib_autohi    = require('litee.lib.highlights.auto')
local lib_hi        = require('litee.lib.highlights')
local lib_path      = require('litee.lib.util.path')

local M = {}

-- prepare_buf ensures that the buffer backing a calltree node is ready to be
-- displayed inside a normal window.  When a file is first touched via
-- `bufadd()/bufload()` it will exist as an unloaded "hidden" buffer that never
-- triggered BufRead autocommands nor detected its filetype.  Without the
-- correct filetype Neovim will skip syntax highlighting and LSP attachments,
-- which caused the "主题/LSP 不生效" symptoms reported by users.  This helper
-- therefore:
--   1. Checks the buffer validity before doing anything expensive.
--   2. Tries to read the `filetype` option; failing to read options is a hint
--      that the buffer is going away, so we abort early.
--   3. If the buffer has no filetype yet, we manually fire the BufRead/
--      BufReadPost events and rerun filetype detection so that syntax groups
--      and language servers have a chance to attach.
-- The helper returns `true` only when the buffer is safe to keep using.
local function prepare_buf(buf, path)
    if not vim.api.nvim_buf_is_valid(buf) then
        return false
    end

    local ok, ft = pcall(vim.api.nvim_buf_get_option, buf, "filetype")
    if not ok then
        return false
    end

    if ft == "" then
        if vim.api.nvim_exec_autocmds ~= nil then
            pcall(vim.api.nvim_exec_autocmds, "BufRead", { buffer = buf, modeline = false })
            pcall(vim.api.nvim_exec_autocmds, "BufReadPost", { buffer = buf, modeline = false })
        end

        if vim.filetype ~= nil and vim.filetype.match ~= nil then
            local match_ok, detected = pcall(vim.filetype.match, { buf = buf, filename = path })
            if match_ok and detected ~= nil and detected ~= "" then
                pcall(vim.api.nvim_buf_set_option, buf, "filetype", detected)
            end
        end
    end

    return true
end

-- fire_win_autocmds simulates the standard window-entering sequence for the
-- target buffer.  When we push an unseen buffer into the invoking window via
-- `nvim_win_set_buf`, Neovim will not automatically emit BufWinEnter/BufEnter/
-- WinEnter for that window.  Many statusline, colorscheme and LSP plugins hook
-- into those autocmds, so skipping them would leave the window in an
-- uninitialised state.  Wrapping the autocmd calls in `pcall` prevents noisy
-- errors from user-defined handlers.
local function fire_win_autocmds(win, buf)
    if vim.api.nvim_exec_autocmds == nil then
        return
    end

    vim.api.nvim_win_call(win, function()
        pcall(vim.api.nvim_exec_autocmds, "BufWinEnter", { buffer = buf, modeline = false })
        pcall(vim.api.nvim_exec_autocmds, "BufEnter", { buffer = buf, modeline = false })
        pcall(vim.api.nvim_exec_autocmds, "WinEnter", { buffer = buf })
    end)
end

-- ensure_window_has_buf guarantees that the provided window actually displays
-- the target buffer.  If the window already shows the buffer we simply keep it
-- as-is; otherwise we swap the buffer in and immediately replay the window
-- autocmd sequence to mimic a genuine user-initiated switch.  Returning `true`
-- lets callers know they can continue working with this window list.
local function ensure_window_has_buf(win, buf)
    if not vim.api.nvim_win_is_valid(win) then
        return false
    end
    if not vim.api.nvim_buf_is_valid(buf) then
        return false
    end

    if vim.api.nvim_win_get_buf(win) ~= buf then
        vim.api.nvim_win_set_buf(win, buf)
        fire_win_autocmds(win, buf)
    end
    return true
end

-- ensure_node_buf converts an LSP calltree node into a valid buffer handle.  It
-- accepts both incoming and outgoing nodes, extracts their `uri`, resolves the
-- on-disk path and then ensures the buffer is loaded via `bufadd`/`bufload`.
-- Afterwards we delegate to `prepare_buf` so the buffer behaves like an openly
-- edited file.  Any failure (missing uri, load error, invalid buffer, etc.)
-- results in a `nil` return which upstream callers treat as "skip this node".
local function ensure_node_buf(node)
    if node == nil or node.location == nil or node.location.uri == nil then
        return nil
    end

    local path = lib_path.strip_file_prefix(node.location.uri)
    if path == nil or path == "" then
        return nil
    end

    local buf = vim.fn.bufadd(path)
    if vim.fn.bufloaded(buf) == 0 then
        local ok = pcall(vim.fn.bufload, buf)
        if not ok then
            return nil
        end
    end

    if not prepare_buf(buf, path) then
        return nil
    end

    if not vim.api.nvim_buf_is_valid(buf) then
        return nil
    end

    return buf
end

-- normalize_lsp_line converts the 0-indexed line numbers returned by LSP into a
-- safe value for Neovim API calls.  LSP servers can report stale or off-by-one
-- ranges when files change on disk; this helper clamps the line to the final
-- valid row (line_count - 1) so highlighting and cursor movement stay within
-- bounds.  Returning `nil` indicates the input was hopelessly invalid (negative
-- or empty buffer).
local function normalize_lsp_line(buf, line)
    if not vim.api.nvim_buf_is_valid(buf) then
        return nil
    end

    local line_count = vim.api.nvim_buf_line_count(buf)
    if line_count == 0 then
        return nil
    end

    if line < 0 then
        return nil
    end

    if line < line_count then
        return line
    end

    if line == line_count then
        return line_count - 1
    end

    return nil
end

-- safe_buf_add_highlight wraps `nvim_buf_add_highlight` with the normalisation
-- guard above.  When the line falls outside the buffer we skip adding the
-- highlight instead of throwing an exception, keeping calltree navigation
-- responsive even when references go stale.
local function safe_buf_add_highlight(buf, ns, hl_group, line, start_col, end_col)
    local normalized = normalize_lsp_line(buf, line)
    if normalized == nil then
        return false
    end

    vim.api.nvim_buf_add_highlight(buf, ns, hl_group, normalized, start_col, end_col)
    return true
end

-- safe_win_set_cursor is the cursor-moving counterpart to the highlight guard:
-- it validates the target window and buffer, runs the line number through
-- `normalize_lsp_line`, then attempts to move the cursor.  Callers treat the
-- boolean return as a success flag when searching for a window that can accept
-- the jump.
local function safe_win_set_cursor(win, pos)
    if not vim.api.nvim_win_is_valid(win) then
        return false
    end

    local buf = vim.api.nvim_win_get_buf(win)
    if not vim.api.nvim_buf_is_valid(buf) then
        return false
    end

    local normalized = normalize_lsp_line(buf, pos[1] - 1)
    if normalized == nil then
        return false
    end

    vim.api.nvim_win_set_cursor(win, { normalized + 1, pos[2] })
    return true
end

-- target_buf_for_node selects the buffer we should highlight or jump within.
-- For incoming calltrees (`direction == "to"`) or the root node we always
-- highlight inside the original invoking buffer; outgoing calls use the
-- callee's file resolved via `ensure_node_buf`.  Returning `nil` signals that we
-- could not prepare an actionable target for this node.
local function target_buf_for_node(ctx, node)
    local calltree = ctx.state and ctx.state["calltree"]
    if calltree == nil then
        return nil
    end

    if calltree.direction == "to" or node.depth == 0 then
        return calltree.invoking_buf
    end
    return ensure_node_buf(node)
end

-- target_wins determines which windows should receive the highlight/jump.
-- Priority is given to any existing windows already showing the buffer; when
-- none are found we fall back to the calltree invocation window and swap the
-- buffer in using `ensure_window_has_buf`.  The function may return an empty
-- list, allowing callers to gracefully skip cursor moves when no suitable
-- window exists (for example in headless sessions).
local function target_wins(ctx, buf)
    local calltree = ctx.state and ctx.state["calltree"]
    if buf == nil or not vim.api.nvim_buf_is_valid(buf) or calltree == nil then
        return {}
    end

    local wins = vim.fn.win_findbuf(buf)
    if #wins > 0 then
        return wins
    end

    local invoking_win = calltree.invoking_win
    if invoking_win == nil then
        return {}
    end

    if ensure_window_has_buf(invoking_win, buf) then
        wins = vim.fn.win_findbuf(buf)
    end

    return wins
end

-- jump_to_reference iterates all candidate windows and tries to place the
-- cursor at the reference's starting position.  It returns `true` as soon as at
-- least one window succeeded, which downstream logic uses to decide whether the
-- jump state (`M.last_jumped_reference`) should advance to this reference.
local function jump_to_reference(wins, ref)
    local moved = false
    for _, win in ipairs(wins) do
        if safe_win_set_cursor(win, { ref["start"].line + 1, 0 }) then
            moved = true
        end
    end
    return moved
end

-- ui_req_ctx creates a context table summarizing the
-- environment when a calltree request is being
-- made.
--
-- see return type for details.
local function ui_req_ctx()
    local buf    = vim.api.nvim_get_current_buf()
    local win    = vim.api.nvim_get_current_win()
    local tab    = vim.api.nvim_win_get_tabpage(win)
    local linenr = vim.api.nvim_win_get_cursor(win)
    local tree_type   = lib_state.get_type_from_buf(tab, buf)
    local tree_handle = lib_state.get_tree_from_buf(tab, buf)
    local state       = lib_state.get_state(tab)

    local cursor = nil
    local node = nil
    if state ~= nil then
        if state["calltree"] ~= nil and state["calltree"].win ~= nil and
            vim.api.nvim_win_is_valid(state["calltree"].win) then
            cursor = vim.api.nvim_win_get_cursor(state["calltree"].win)
        end
        node = lib_tree.marshal_line(cursor, state["calltree"].tree)
    end

    return {
        -- the current buffer when the request is made
        buf = buf,
        -- the current win when the request is made
        win = win,
        -- the current tab when the request is made
        tab = tab,
        -- the current cursor pos when the request is made
        linenr = linenr,
        -- the type of tree if request is made in a lib_panel
        -- window.
        tree_type = tree_type,
        -- a hande to the tree if the request is made in a lib_panel
        -- window.
        tree_handle = tree_handle,
        -- the pos of the calltree cursor if a valid caltree exists.
        cursor = cursor,
        -- the current state provided by lib_state
        state = state,
        -- the current marshalled node if there's a valid calltree
        -- window present.
        node = node
    }
end

-- auto_highlight will automatically highlight
-- symbols in the source code files when the symbol
-- is selected.
--
-- if set is false it will remove any highlights
-- in the source code's buffer.
--
-- this method is intended for use as an autocommand.
--
-- @param set (bool) Whether to remove or set highlights
-- for the symbol under the cursor in a calltree.
M.auto_highlight = function(set)
    local ctx = ui_req_ctx()
    if ctx.node == nil then
        return
    end
    lib_autohi.highlight(ctx.node, set, ctx.state["calltree"].invoking_win)
end

M.highlight_ns = vim.api.nvim_create_namespace("calltree-node-hls")

M.last_jumped_reference = nil
M.last_highlight_buf = nil

function M.jumpto_next_reference()
    -- `M.last_jumped_reference` stores the node and index we successfully
    -- jumped to when highlighting the tree entry.  Reusing that state allows the
    -- user to press `j/k` (or other mapped keys) and cycle through the remaining
    -- references without recomputing expensive context.  If the stored state no
    -- longer matches the current node we silently abort to avoid confusing
    -- cursor jumps.
    if M.last_jumped_reference == nil then
        return
    end

    local ctx = ui_req_ctx()
    if ctx.node == nil then
        return
    end

    if ctx.node.key ~= M.last_jumped_reference.node_key then
        return
    end

    if ctx.node.references == nil or #ctx.node.references == 0 then
        return
    end

    local target_buf = target_buf_for_node(ctx, M.last_jumped_reference.node)
    if target_buf == nil then
        return
    end

    local wins = target_wins(ctx, target_buf)
    if #wins == 0 then
        return
    end

    local ref_idx = M.last_jumped_reference.ref_idx
    for _ = 1, #ctx.node.references do
        ref_idx = ref_idx + 1
        if ref_idx > #ctx.node.references then
            ref_idx = 1
        end
        local ref = ctx.node.references[ref_idx]
        if jump_to_reference(wins, ref) then
            M.last_jumped_reference = {
                node_key = ctx.node.key,
                ref_idx = ref_idx,
                node = M.last_jumped_reference.node,
            }
            return
        end
    end
end

function M.highlight(set)
    -- Highlight is invoked whenever the calltree selection changes.  It
    -- prepares the target buffer and windows using the helpers above and then
    -- either clears highlights (`set == false`) or paints/jumps to the first
    -- valid reference.  The logic mirrors Neovim's native LSP handlers so that
    -- calltree navigation feels identical to built-in references requests.
    local ctx = ui_req_ctx()
    if ctx.node == nil or ctx.state["calltree"] == nil then
        return
    end

    local target_buf = target_buf_for_node(ctx, ctx.node)
    if target_buf == nil or not vim.api.nvim_buf_is_valid(target_buf) then
        M.last_jumped_reference = nil
        return
    end

    if M.last_highlight_buf ~= nil and
        vim.api.nvim_buf_is_valid(M.last_highlight_buf) and
        M.last_highlight_buf ~= target_buf then
        vim.api.nvim_buf_clear_namespace(M.last_highlight_buf, M.highlight_ns, 0, -1)
    end

    vim.api.nvim_buf_clear_namespace(target_buf, M.highlight_ns, 0, -1)

    if not set then
        M.last_highlight_buf = target_buf
        return
    end

    local wins = target_wins(ctx, target_buf)

    if ctx.node.depth == 0 then
        local location = ctx.node.location
        if location == nil or location.range == nil then
            M.last_highlight_buf = target_buf
            return
        end
        local range = location.range
        safe_buf_add_highlight(
            target_buf,
            M.highlight_ns,
            lib_hi.hls.SymbolJumpHL,
            range["start"].line,
            range["start"].character,
            range["end"].character
        )
        for _, win in ipairs(wins) do
            safe_win_set_cursor(win, { range["start"].line + 1, 0 })
        end
        M.last_highlight_buf = target_buf
        return
    end

    if ctx.node.references ~= nil then
        local first_valid = nil
        for i, ref in ipairs(ctx.node.references) do
            local highlighted = safe_buf_add_highlight(
                target_buf,
                M.highlight_ns,
                lib_hi.hls.SymbolJumpHL,
                ref["start"].line,
                ref["start"].character,
                ref["end"].character
            )
            local jumped = false
            if first_valid == nil then
                jumped = jump_to_reference(wins, ref)
            end
            if first_valid == nil and (highlighted or jumped) then
                first_valid = i
            end
        end

        if first_valid ~= nil then
            M.last_jumped_reference = {
                node_key = ctx.node.key,
                ref_idx = first_valid,
                node = ctx.node,
            }
        else
            M.last_jumped_reference = nil
        end
    else
        M.last_jumped_reference = nil
    end

    if ctx.node.references == nil or #ctx.node.references == 0 then
        M.last_jumped_reference = nil
    end

    M.last_highlight_buf = target_buf
end

return M
