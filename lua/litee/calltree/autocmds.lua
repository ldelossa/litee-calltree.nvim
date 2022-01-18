local lib_state     = require("litee.lib.state")
local lib_tree      = require("litee.lib.tree")
local lib_autohi    = require('litee.lib.highlights.auto')

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

return M
