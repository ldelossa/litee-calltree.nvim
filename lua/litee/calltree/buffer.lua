local config = require('litee.calltree.config').config
local panel_config = require('litee.lib.config').config["panel"]
local lib_util_buf = require('litee.lib.util.buffer')
local autocmds = require('litee.calltree.autocmds')

local M = {}

-- _setup_buffer performs an idempotent creation of
-- a calltree buffer.
function M._setup_buffer(name, buf, tab)
    -- see if we can reuse a buffer that currently exists.
    if buf == nil or not vim.api.nvim_buf_is_valid(buf) then
        buf = vim.api.nvim_create_buf(false, false)
        if buf == 0 then
            vim.api.nvim_err_writeln("calltree.buffer: buffer create failed")
            return
        end
    else
        return buf
    end

    -- set buf options
    vim.api.nvim_buf_set_name(buf, name .. ":" .. tab)
    vim.api.nvim_buf_set_option(buf, 'bufhidden', 'hide')
    vim.api.nvim_buf_set_option(buf, 'filetype', 'calltree')
    vim.api.nvim_buf_set_option(buf, 'buftype', 'nofile')
    vim.api.nvim_buf_set_option(buf, 'modifiable', false)
    vim.api.nvim_buf_set_option(buf, 'swapfile', false)
    vim.api.nvim_buf_set_option(buf, 'textwidth', 0)
    vim.api.nvim_buf_set_option(buf, 'wrapmargin', 0)

    -- au to clear jump highlights on window close
    vim.cmd("au BufWinLeave <buffer=" .. buf .. "> lua require('litee.lib.jumps').set_jump_hl(false)")

    -- hide the cursor if possible since there's no need for it, resizing the panel should be used instead.
    if config.hide_cursor then
        vim.cmd("au WinLeave <buffer=" .. buf .. "> lua require('litee.lib.util.buffer').hide_cursor(false)")
        vim.cmd("au WinEnter <buffer=" .. buf .. "> lua require('litee.lib.util.buffer').hide_cursor(true)")
    end

    -- au to (re)set source code highlights when a calltree node is hovered.
    if config.auto_highlight then
        vim.cmd("au CursorMoved <buffer=" .. buf .. "> lua require('litee.calltree.autocmds').highlight(true)")
    end

    -- set buffer local keymaps
    local opts = {silent=true, noremap=true}
    if not config.disable_keymaps then
        vim.api.nvim_buf_set_keymap(buf, "n", config.keymaps.expand, ":LTExpandCalltree<CR>", opts)
        vim.api.nvim_buf_set_keymap(buf, "n", config.keymaps.collapse, ":LTCollapseCalltree<CR>", opts)
        vim.api.nvim_buf_set_keymap(buf, "n", config.keymaps.collapse_all, ":LTCollapseAllCalltree<CR>", opts)
        vim.api.nvim_buf_set_keymap(buf, "n", config.keymaps.jump, ":LTJumpCalltree<CR>", opts)
        vim.api.nvim_buf_set_keymap(buf, "n", config.keymaps.jump_split, ":LTJumpCalltreeSplit<CR>", opts)
        vim.api.nvim_buf_set_keymap(buf, "n", config.keymaps.jump_vsplit, ":LTJumpCalltreeVSplit<CR>", opts)
        vim.api.nvim_buf_set_keymap(buf, "n", config.keymaps.jump_tab, ":LTJumpCalltreeTab<CR>", opts)
        vim.api.nvim_buf_set_keymap(buf, "n", config.keymaps.hover, ":LTHoverCalltree<CR>", opts)
        vim.api.nvim_buf_set_keymap(buf, "n", config.keymaps.details, ":LTDetailsCalltree<CR>", opts)
        vim.api.nvim_buf_set_keymap(buf, "n", config.keymaps.hide, ":LTHideCalltree<CR>", opts)
        vim.api.nvim_buf_set_keymap(buf, "n", config.keymaps.close, ":LTCloseCalltree<CR>", opts)
        vim.api.nvim_buf_set_keymap(buf, "n", config.keymaps.close_panel_pop_out, ":LTClosePanelPopOut<CR>", opts)
        vim.api.nvim_buf_set_keymap(buf, "n", config.keymaps.help, ":lua require('litee.calltree').help(true)<CR>", opts)
        vim.api.nvim_buf_set_keymap(buf, "n", config.keymaps.focus, ":LTFocusCalltree<CR>", opts)
        vim.api.nvim_buf_set_keymap(buf, "n", config.keymaps.switch, ":LTSwitchCalltree<CR>", opts)
        vim.api.nvim_buf_set_keymap(buf, "n", config.keymaps.next_ref, "", {silent=true, noremap=true, callback=autocmds.jumpto_next_reference})
    end
	if config.map_resize_keys then
           lib_util_buf.map_resize_keys(panel_config.orientation, buf, opts)
    end
    return buf
end


return M
