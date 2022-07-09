local lib_state     = require("litee.lib.state")
local lib_tree      = require("litee.lib.tree")
local lib_autohi    = require('litee.lib.highlights.auto')
local lib_hi        = require('litee.lib.highlights')
local lib_path          = require('litee.lib.util.path')

local M = {}

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

function M.jumpto_next_reference()
    if M.last_jumped_reference == nil then
        return
    end
    local ctx = ui_req_ctx()
    if ctx.node == nil then
        return
    end
    if
        ctx.node.key ~= M.last_jumped_reference.node_key
    then
        return
    end
    local wins = {}
    if ctx.state["calltree"].direction == "to" then
        for _, win in ipairs(vim.api.nvim_list_wins()) do
            if vim.api.nvim_win_get_buf(win) == ctx.state["calltree"].invoking_buf then
                table.insert(wins, win)
            end
        end
    else
            local node_path = lib_path.strip_file_prefix(M.last_jumped_reference.node.location.uri)
        for _, win in ipairs(vim.api.nvim_list_wins()) do
            local buf = vim.api.nvim_win_get_buf(win)
            local name = vim.api.nvim_buf_get_name(buf)
            if node_path == name then
                table.insert(wins, win)
            end
        end
    end

    local i = M.last_jumped_reference.ref_idx
    i = i + 1
    if i > #ctx.node.references then
        i = 1
    end
    local ref = ctx.node.references[i]
    for _, win in ipairs(wins) do
        vim.api.nvim_win_set_cursor(win, {ref["start"].line+1, 0})
    end
    M.last_jumped_reference = {
        node_key = ctx.node.key,
        ref_idx = i,
        node = M.last_jumped_reference.node
    }
end

function M.highlight(set)
    local ctx = ui_req_ctx()
    if ctx.node == nil then
        return
    end

    if ctx.state["calltree"].invoking_buf == nil or
        not vim.api.nvim_buf_is_valid(ctx.state["calltree"].invoking_buf) then
        return
    end

    local wins = {}
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(win) == ctx.state["calltree"].invoking_buf then
            table.insert(wins, win)
        end
    end

    vim.api.nvim_buf_clear_namespace(
        ctx.state["calltree"].invoking_buf,
        M.highlight_ns,
        0,
        -1
    )
    if not set then
        return
    end

    -- highlight root node
    if ctx.node.depth == 0 then
        local location = ctx.node.location
        if location == nil then
            return
        end
        local range = location.range
        vim.api.nvim_buf_add_highlight(
            ctx.state["calltree"].invoking_buf,
            M.highlight_ns,
            lib_hi.hls.SymbolJumpHL,
            range["start"].line,
            range["start"].character,
            range["end"].character
        )
        for _, win in ipairs(wins) do
            vim.api.nvim_win_set_cursor(win, {range["start"].line+1, 0})
        end
        return
    end

    -- highlight references
    if ctx.state["calltree"].direction == "to" then
        if ctx.node.references ~= nil then
            for i, ref in ipairs(ctx.node.references) do
                vim.api.nvim_buf_add_highlight(
                    ctx.state["calltree"].invoking_buf,
                    M.highlight_ns,
                    lib_hi.hls.SymbolJumpHL,
                    ref["start"].line,
                    ref["start"].character,
                    ref["end"].character
                )
                if i == 1 then
                    for _, win in ipairs(wins) do
                        vim.api.nvim_win_set_cursor(win, {ref["start"].line+1, 0})
                    end
                    M.last_jumped_reference = {
                        node_key = ctx.node.key,
                        ref_idx = 1,
                        node = ctx.node
                    }
                end
            end
        end
    else
        local wins = {}
        -- do a buffer search for node's location
        local node_path = lib_path.strip_file_prefix(ctx.node.location.uri)
        for _, win in ipairs(vim.api.nvim_list_wins()) do
            local buf = vim.api.nvim_win_get_buf(win)
            local name = vim.api.nvim_buf_get_name(buf)
            if node_path == name then
                table.insert(wins, win)
            end
        end
        if #wins > 0 then
            for i, ref in ipairs(ctx.node.references) do
                vim.api.nvim_buf_add_highlight(
                    ctx.state["calltree"].invoking_buf,
                    M.highlight_ns,
                    lib_hi.hls.SymbolJumpHL,
                    ref["start"].line,
                    ref["start"].character,
                    ref["end"].character
                )
                if i == 1 then
                    for _, win in ipairs(wins) do
                        vim.api.nvim_win_set_cursor(win, {ref["start"].line+1, 0})
                    end
                    M.last_jumped_reference = {
                        node_key = ctx.node.key,
                        ref_idx = 1,
                        node = ctx.node
                    }
                end
            end
        end
    end
end

return M
