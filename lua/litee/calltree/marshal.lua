local lib_util = require('litee.lib.util')

local M = {}

-- marshal_func is a function which returns the necessary
-- values for marshalling a calltree node into a buffer
-- line.
function M.marshal_func(node)
    local icon_set = require('litee.calltree').icon_set
    local location = node.location
    local name, detail, icon = "", "", ""
    -- prefer the symbol info if available
    if node.symbol ~= nil then
        references = (function() if node.references ~= nil then return #node.references else return "" end end)()
        name = node.symbol.name
        local kind = vim.lsp.protocol.SymbolKind[node.symbol.kind]
        if kind ~= "" then
            icon = icon_set[kind] or "[" .. kind .. "]"
        end
        local file, relative = lib_util.relative_path_from_uri(location.uri)
        if relative then
            detail = file .. " " .. references
        elseif node.symbol.detail ~= nil then
            detail = node.symbol.detail .. " " .. references
        end
    elseif node.call_hierarchy_item ~= nil then
        references = (function() if node.references ~= nil then return #node.references else return "" end end)()
        name = node.name
        local kind = vim.lsp.protocol.SymbolKind[node.call_hierarchy_item.kind]
        if kind ~= "" then
            icon = icon_set[kind] or "[" .. kind .. "]"
        end
        local file, relative = lib_util.relative_path_from_uri(location.uri)
        if relative then
            detail = file .. " " .. references
        elseif node.call_hierarchy_item.detail ~= nil then
            detail = node.call_hierarchy_item.detail .. " " .. references
        end
    end
    return name, detail, icon
end

return M
