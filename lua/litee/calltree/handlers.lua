local lib_state         = require('litee.lib.state')
local lib_panel         = require('litee.lib.panel')
local lib_tree          = require('litee.lib.tree')
local lib_tree_node     = require('litee.lib.tree.node')
local lib_lsp           = require('litee.lib.lsp')
local lib_notify        = require('litee.lib.notify')
local lib_util_win      = require('litee.lib.util.window')
local lib_path          = require('litee.lib.util.path')

local config            = require('litee.calltree.config').config
local calltree_marshal  = require('litee.calltree.marshal')

local M = {}

-- direction_map maps the call hierarchy lsp method to our buffer name
local direction_map = {
    from = {method ="callHierarchy/incomingCalls", buf_name="incomingCalls"},
    to   = {method="callHierarchy/outgoingCalls", buf_name="outgoingCalls"},
    empty = {method="callHierarchy/outgoingCalls", buf_name="calltree: empty"}
}

local function keyify(call_hierarchy_item)
    if call_hierarchy_item ~= nil then
        local key = call_hierarchy_item.name .. ":" ..
                call_hierarchy_item.uri .. ":" ..
                    call_hierarchy_item.range.start.line
        return key
    end
end

local update_autocmd_id = nil

-- ch_lsp_handler is the call heirarchy handler
-- used in replacement to the default lsp handler.
--
-- this handler serves as the single entry point for creating
-- a calltree.
local function resolve_offset_encoding(ctx)
    if ctx == nil then
        return "utf-16"
    end
    if ctx.offset_encoding ~= nil then
        return ctx.offset_encoding
    end
    if ctx.client_id ~= nil and vim.lsp.get_client_by_id ~= nil then
        local client = vim.lsp.get_client_by_id(ctx.client_id)
        if client ~= nil and client.offset_encoding ~= nil then
            return client.offset_encoding
        end
    end
    return "utf-16"
end

M.ch_lsp_handler = function(direction)
    return function(err, result, ctx, _)
        if err ~= nil then
            return
        end
        if result == nil then
            return
        end

        if update_autocmd_id ~= nil then
            vim.api.nvim_del_autocmd(update_autocmd_id)
        end

        local cur_buf = vim.api.nvim_get_current_buf()
        local cur_win = vim.api.nvim_get_current_win()
        local cur_tabpage = vim.api.nvim_win_get_tabpage(cur_win)
        local state_was_nil = false

        local state = lib_state.get_component_state(cur_tabpage, "calltree")
        if state == nil then
            -- initial new state
            state_was_nil = true
            state = {}
            -- remove existing tree from memory if exists
            if state.tree ~= nil then
                lib_tree.remove_tree(state.tree)
            end
            -- create a new tree.
            state.tree = lib_tree.new_tree("calltree")
            -- snag the lsp clients from the buffer issuing the
            -- call hierarchy request
            state.active_lsp_clients = (vim.lsp.get_clients or vim.lsp.get_active_clients)()
            -- store the window invoking the call tree, jumps will
            -- occur here.
            state.invoking_win = vim.api.nvim_get_current_win()
            -- store what direction the call tree is being invoked
            -- with.
            state.direction = direction
            -- store the tab which triggered the lsp call.
            state.tab = cur_tabpage
            -- store the invoking buffer.
            state.invoking_buf = cur_buf
        end
        -- swap directions so highlighting knows what's up.
        state.direction = direction

        -- create the root of our call tree, the request which
        -- signaled this response is in ctx.params
        local offset_encoding = resolve_offset_encoding(ctx)

        local root = lib_tree_node.new_node(ctx.params.item.name, keyify(ctx.params.item), 0)
        root.call_hierarchy_item = ctx.params.item
        root.location = {
            uri = root.call_hierarchy_item.uri,
            range = root.call_hierarchy_item.range
        }
        root.references = ctx.params.item.fromRanges
        root.offset_encoding = offset_encoding

        -- create the root's children nodes via the response array.
        local children = {}
        for _, call_hierarchy_call in pairs(result) do
          local child = lib_tree_node.new_node(
             call_hierarchy_call[direction].name,
             keyify(call_hierarchy_call[direction])
          )
          child.call_hierarchy_item = call_hierarchy_call[direction]
          child.location = {
              uri = child.call_hierarchy_item.uri,
              range = child.call_hierarchy_item.range
          }
          child.references = call_hierarchy_call["fromRanges"]
          child.offset_encoding = offset_encoding
          table.insert(children, child)
        end

        -- if lsp.wrappers are being used this closes the notification
        -- popup.
        lib_notify.close_notify_popup()

        -- update component state and grab the global since we need it to toggle
        -- the panel open.
        local global_state = lib_state.put_component_state(cur_tabpage, "calltree", state)

        -- gather symbols async
        if config.resolve_symbols then
            lib_lsp.gather_symbols_async(root, children, state, function()
                lib_tree.add_node(state.tree, root, children)
                -- lib_panel.toggle_panel(global_state, false, true)
                -- state was not nil, can we reuse the existing win
                -- and buffer?
                if
                    not state_was_nil
                    and state.win ~= nil
                    and vim.api.nvim_win_is_valid(state.win)
                    and state.buf ~= nil
                    and vim.api.nvim_buf_is_valid(state.buf)
                then
                    lib_tree.write_tree(
                        state.buf,
                        state.tree,
                        calltree_marshal.marshal_func
                    )
                else
                    -- we have no state, so open up the panel or popout to create
                    -- a window and buffer.
                    if config.on_open == "popout" then
                        lib_panel.popout_to("calltree", global_state)
                    else
                        lib_panel.toggle_panel(global_state, true, false)
                    end
                end
            end)
                -- setup an autocmd for this buffer to keep symbols update to date.
                update_autocmd_id = vim.api.nvim_create_autocmd(
                    {"CursorHold","TextChanged","BufEnter","BufWritePost","WinEnter"},
                    {
                        buffer = state.cur_buf,
                        callback = M.update_calltree_extmarks
                    }
                )
            return
        end
        lib_tree.add_node(state.tree, root, children)

        -- state was not nil, can we reuse the existing win
        -- and buffer?
        if
            not state_was_nil
            and state.win ~= nil
            and vim.api.nvim_win_is_valid(state.win)
            and state.buf ~= nil
            and vim.api.nvim_buf_is_valid(state.buf)
        then
            lib_tree.write_tree(
                state.buf,
                state.tree,
                calltree_marshal.marshal_func
            )
        else
            -- we have no state, so open up the panel or popout to create
            -- a window and buffer.
            if config.on_open == "popout" then
                lib_panel.popout_to("calltree", global_state)
            else
                lib_panel.toggle_panel(global_state, true, false)
            end
        end

        -- setup an autocmd for this buffer to keep symbols update to date.
        update_autocmd_id = vim.api.nvim_create_autocmd(
            {"CursorHold","TextChanged","BufEnter","BufWritePost","WinEnter"},
            {
                buffer = cur_buf,
                callback = M.update_calltree_extmarks
            }
        )
   end
end

-- calltree_expand_handler is the call_hierarchy request handler
-- used when expanding an existing node in the calltree.
--
-- node : tree.node.Node - the node being expanded
--
-- linenr : table - the line the cursor was on in the ui
-- buffer before expand writes to it.
--
-- direction : string - the call hierarchy direction
-- "to" or "from".
--
-- ui_state : table - a ui_state table which provides the ui state
-- of the current tab. defined in ui.lua
function M.calltree_expand_handler(node, linenr, direction, state)
    return function(err, result, ctx, _)
        if err ~= nil then
            vim.api.nvim_err_writeln(vim.inspect(err))
            return
        end
        if result == nil then
            -- rewrite the tree still to expand node giving ui
            -- feedback that no further callers/callees exist
            lib_tree.write_tree_no_guide_leaf(
                state["calltree"].buf,
                state["calltree"].tree,
                require('litee.calltree.marshal').marshal_func
            )
            vim.api.nvim_win_set_cursor(state["calltree"].win, linenr)
            return
        end

        local offset_encoding = resolve_offset_encoding(ctx)

        local children = {}
        for _, call_hierarchy_call in pairs(result) do
            local child = lib_tree_node.new_node(
               call_hierarchy_call[direction].name,
               keyify(call_hierarchy_call[direction])
            )
            child.call_hierarchy_item = call_hierarchy_call[direction]
            child.location = {
                uri = child.call_hierarchy_item.uri,
                range = child.call_hierarchy_item.range
            }
            child.references = call_hierarchy_call["fromRanges"]
            child.offset_encoding = offset_encoding
            table.insert(children, child)
        end

        if config.resolve_symbols then
            lib_lsp.gather_symbols_async(node, children, state["calltree"], function()
                lib_tree.add_node(state["calltree"].tree, node, children)
                lib_tree.write_tree_no_guide_leaf(
                    state["calltree"].buf,
                    state["calltree"].tree,
                    require('litee.calltree.marshal').marshal_func
                )
                vim.api.nvim_win_set_cursor(state["calltree"].win, linenr)
            end)
            vim.api.nvim_win_set_cursor(state["calltree"].win, linenr)
            return
        end

        lib_tree.add_node(state["calltree"].tree, node, children)
        lib_tree.write_tree_no_guide_leaf(
            state["calltree"].buf,
            state["calltree"].tree,
            require('litee.calltree.marshal').marshal_func
        )
        vim.api.nvim_win_set_cursor(state["calltree"].win, linenr)
    end
end

-- calltree_switch_handler is the call_hierarchy request handler
-- used when switching directions from incoming to outgoing or vice versa.
--
-- direction : string - the call hierarchy direction
-- "to" or "from".
--
-- ui_state : table - a ui_state table which provides the ui state
-- of the current tab. defined in ui.lua
function M.calltree_switch_handler(direction, state)
    return function(err, result, ctx, _)
        if err ~= nil or result == nil then
            return
        end
        local offset_encoding = resolve_offset_encoding(ctx)
        -- create the root of our call tree, the request which
        -- signaled this response is in ctx.params
        local root = lib_tree_node.new_node(ctx.params.item.name, keyify(ctx.params.item), 0)
        root.call_hierarchy_item = ctx.params.item
        root.location = {
            uri = root.call_hierarchy_item.uri,
            range = root.call_hierarchy_item.range
        }
        root.offset_encoding = offset_encoding

        -- try to resolve the workspace symbol for root
        root.symbol = lib_lsp.symbol_from_node(state["calltree"].active_lsp_clients, root, state["calltree"].buf)

        -- create the root's children nodes via the response array.
        local children = {}
        for _, call_hierarchy_call in pairs(result) do
            local child = lib_tree_node.new_node(
               call_hierarchy_call[direction].name,
               keyify(call_hierarchy_call[direction])
            )
            child.call_hierarchy_item = call_hierarchy_call[direction]
            child.location = {
                uri = child.call_hierarchy_item.uri,
                range = child.call_hierarchy_item.range
            }
            child.references = call_hierarchy_call["fromRanges"]
            child.offset_encoding = offset_encoding
            table.insert(children, child)
        end

        if config.resolve_symbols then
            lib_lsp.gather_symbols_async(root, children, state["calltree"], function()
                lib_tree.add_node(state["calltree"].tree, root, children)
                lib_tree.write_tree_no_guide_leaf(
                    state["calltree"].buf,
                    state["calltree"].tree,
                    require('litee.calltree.marshal').marshal_func
                )
                vim.api.nvim_buf_set_name(state["calltree"].buf, direction_map[direction].buf_name .. ":" .. state["calltree"].tab)
            end)
            return
        end

        lib_tree.add_node(state["calltree"].tree, root, children)
        lib_tree.write_tree_no_guide_leaf(
            state["calltree"].buf,
            state["calltree"].tree,
            require('litee.calltree.marshal').marshal_func
        )
        -- swap directions so highlighting knows what's up.
        state.direction = direction
    end
end

local ns_id = vim.api.nvim_create_namespace("calltree-extmarks")

local function clamp_line(buf, line)
    if line == nil then
        return 0
    end
    local line_count = 0
    if buf ~= nil then
        local ok, count = pcall(vim.api.nvim_buf_line_count, buf)
        if ok and type(count) == "number" then
            line_count = count
        end
    end
    if line_count <= 0 then
        return math.max(line, 0)
    end
    if line < 0 then
        return 0
    end
    if line >= line_count then
        return line_count - 1
    end
    return line
end

local function clamp_col(buf, line, col)
    if col == nil then
        return 0
    end
    if col < 0 then
        return 0
    end
    if buf ~= nil and line ~= nil then
        local ok, lines = pcall(vim.api.nvim_buf_get_lines, buf, line, line + 1, true)
        if ok and type(lines) == "table" and lines[1] ~= nil then
            local max_col = #lines[1]
            if col > max_col then
                return max_col
            end
        end
    end
    return col
end

local function get_line_byte_from_position(buf, position, offset_encoding)
    if position == nil then
        return 0
    end
    local resolved_encoding = offset_encoding or "utf-16"
    if resolved_encoding == "utf-8" or position._litee_converted then
        return position.character
    end
    local ok, col = pcall(vim.lsp.util._get_line_byte_from_position, buf, position, resolved_encoding)
    if ok and col ~= nil then
        return col
    end
    return position.character
end

local function ensure_range_utf8(buf, range, offset_encoding)
    if range == nil then
        return 0, 0, 0, 0
    end
    local start_line = clamp_line(buf, range["start"].line)
    local end_line = clamp_line(buf, range["end"].line)
    if range._litee_converted then
        range["start"].line = start_line
        range["end"].line = end_line
        range["start"].character = clamp_col(buf, start_line, range["start"].character)
        range["end"].character = clamp_col(buf, end_line, range["end"].character)
        return start_line, range["start"].character, end_line, range["end"].character
    end
    local resolved_encoding = offset_encoding or "utf-16"
    if resolved_encoding ~= "utf-8" then
        range["start"].line = start_line
        range["end"].line = end_line
        local start_col = get_line_byte_from_position(buf, range["start"], resolved_encoding)
        local end_col = get_line_byte_from_position(buf, range["end"], resolved_encoding)
        range["start"].character = clamp_col(buf, start_line, start_col)
        range["end"].character = clamp_col(buf, end_line, end_col)
    else
        range["start"].line = start_line
        range["end"].line = end_line
        range["start"].character = clamp_col(buf, start_line, range["start"].character)
        range["end"].character = clamp_col(buf, end_line, range["end"].character)
    end
    range._litee_converted = true
    range["start"]._litee_converted = true
    range["end"]._litee_converted = true
    return start_line, range["start"].character, end_line, range["end"].character
end

local function _update_calltree_extmarks(node, buf)
    if node.extmark == nil then
        -- extmark is nil, and buffer is open, create a extmark
        local start_line, start_col, end_line, end_col = ensure_range_utf8(buf, node.location.range, node.offset_encoding)
        node.extmark = {
            buf = buf,
            id = vim.api.nvim_buf_set_extmark(
                buf,
                ns_id,
                start_line,
                start_col,
                {
                    end_row = end_line,
                    end_col = end_col,
                }
            )
        }
    else
        -- extmark exists, but node.location maybe out of date, update.
        local extmark_linenr = vim.api.nvim_buf_get_extmark_by_id(
            node.extmark.buf,
            ns_id,
            node.extmark.id,
            {details = false}
        )
        if #extmark_linenr == 2 then
            local relative_line_count = node.location.range["end"].line -
                node.location.range["start"].line
            local relative_char_count = node.location.range["end"].character -
                node.location.range["start"].character
            node.location.range["start"].line = extmark_linenr[1]
            node.location.range["start"].character = extmark_linenr[2]
            node.location.range["end"].line = extmark_linenr[1] + relative_line_count
            node.location.range["end"].character = extmark_linenr[2] + relative_char_count
            node.location.range._litee_converted = true
            node.location.range["start"]._litee_converted = true
            node.location.range["end"]._litee_converted = true
        end
    end
    if node.ref_extmarks == nil and node.references ~= nil then
        -- reference extmarks not created, create them
        local ref_extmarks = {}
        for _, reference in ipairs(node.references) do
            -- extmark is nil, and buffer is open, create a extmark
            local ref_start_line, ref_start_col, ref_end_line, ref_end_col = ensure_range_utf8(buf, reference, node.offset_encoding)
            local extmark = {
                buf = buf,
                id = vim.api.nvim_buf_set_extmark(
                    buf,
                    ns_id,
                    ref_start_line,
                    ref_start_col,
                    {
                        end_row = ref_end_line,
                        end_col = ref_end_col,
                    }
                )
            }
            table.insert(ref_extmarks, extmark)
        end
        node.ref_extmarks = ref_extmarks
    elseif node.references ~= nil then
        for i, ref_extmark in ipairs(node.ref_extmarks) do
            local reference = node.references[i]
            -- extmark exists, but node.location maybe out of date, update.
            local extmark_linenr = vim.api.nvim_buf_get_extmark_by_id(
                ref_extmark.buf,
                ns_id,
                ref_extmark.id,
                {details = false}
            )
            if #extmark_linenr == 2 then
                local relative_line_count = reference["end"].line -
                    reference["start"].line
                local relative_char_count = reference["end"].character -
                    reference["start"].character

                reference["start"].line = extmark_linenr[1]
                reference["start"].character = extmark_linenr[2]
                reference["end"].line = extmark_linenr[1] + relative_line_count
                reference["end"].character = extmark_linenr[2] + relative_char_count
                reference._litee_converted = true
                reference["start"]._litee_converted = true
                reference["end"]._litee_converted = true
            end
        end
    end
end

-- update_calltree_extmarks will run thru all the nodes in
-- the current calltree for the current tab and sync up the
-- node's location field with their extmark (or create an extmark)
-- if necessary.
function M.update_calltree_extmarks()
    local buf       = vim.api.nvim_get_current_buf()
    local win       = vim.api.nvim_get_current_win()
    local tab       = vim.api.nvim_win_get_tabpage(win)
    local state     = lib_state.get_state(tab)
    if
        state == nil or
        state["calltree"] == nil or
        state["calltree"].tree == nil or
        lib_util_win.inside_component_win()
    then
        return
    end

    local t = lib_tree.get_tree(state["calltree"].tree)
    if t.root == nil or t.depth_table == nil then
        return
    end

    local dpt_flat = lib_tree.flatten_depth_table(t.depth_table)

    local name = vim.api.nvim_buf_get_name(buf)
    for _, node in ipairs(dpt_flat) do
        if lib_path.strip_file_prefix(node.location.uri) == name then
            _update_calltree_extmarks(node, buf)
        end
    end
end

return M
