local config = require('litee.calltree.config').config

local M = {}

-- _setup_help_buffer performs an idempotent creation
-- of the calltree help buffer
--
-- help_buf_handle : previous calltree help buffer handle
-- or nil
--
-- returns:
--   "buf_handle"  -- handle to a valid calltree help buffer
function M._setup_help_buffer(help_buf_handle)
    if
        help_buf_handle == nil
        or not vim.api.nvim_buf_is_valid(help_buf_handle)
    then
        local buf = vim.api.nvim_create_buf(false, false)
        if buf == 0 then
            vim.api.nvim_err_writeln("ui.help failed: buffer create failed")
            return
        end
        help_buf_handle = buf
        local lines = {}
        if not config.disable_keymaps then
            lines = {
                "CALLTREE HELP:",
                "press '?' to close",
                "",
                "KEYMAP:",
                config.keymaps.expand .. " - expand a symbol",
                config.keymaps.collapse .. " - collapse a symbol",
                config.keymaps.collapse_all .. " - collapse all symbols",
                config.keymaps.jump .. " - jump to a symbol in last used window",
                config.keymaps.jump_split .. " - jump to symbol in a new split",
                config.keymaps.jump_vsplit .. " - jump to symbol in a new vertical split",
                config.keymaps.jump_tab .. " - jump to symbol in a new tab",
                config.keymaps.hover .. " - show hover info for symbol",
                config.keymaps.close .. " - close the calltree component",
                config.keymaps.details .. " - show symbol details",
                config.keymaps.close_panel_pop_out .. " - close the popout panel when calltree is popped out",
                config.keymaps.help .. " - show help",
                config.keymaps.hide .. " - hide the calltree component",
                config.keymaps.switch .. " - focus the symbol under the cursor and switch calltree directions",
                config.keymaps.focus .. " - focus the symbol under the cursor making it the new root of the calltree",
            }
        else
            lines = {
                "CALLTREE HELP:",
                "press '?' to close",
                "",
                "No KEYMAP set:",
            }
        end
        vim.api.nvim_buf_set_lines(help_buf_handle, 0, #lines, false, lines)
    end
    -- set buf options
    vim.api.nvim_buf_set_name(help_buf_handle, "Calltree Help")
    vim.api.nvim_buf_set_option(help_buf_handle, 'bufhidden', 'hide')
    vim.api.nvim_buf_set_option(help_buf_handle, 'filetype', 'Calltree')
    vim.api.nvim_buf_set_option(help_buf_handle, 'buftype', 'nofile')
    vim.api.nvim_buf_set_option(help_buf_handle, 'modifiable', false)
    vim.api.nvim_buf_set_option(help_buf_handle, 'swapfile', false)

    -- set buffer local keymaps
    local opts = {silent=true, noremap=true}
    vim.api.nvim_buf_set_keymap(help_buf_handle, "n", "?", ":lua require('litee.calltree').help(false)<CR>", opts)

    return help_buf_handle
end

M.help_buffer = M._setup_help_buffer(nil)

return M
