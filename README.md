```
██╗     ██╗████████╗███████╗███████╗   ███╗   ██╗██╗   ██╗██╗███╗   ███╗
██║     ██║╚══██╔══╝██╔════╝██╔════╝   ████╗  ██║██║   ██║██║████╗ ████║ Lightweight
██║     ██║   ██║   █████╗  █████╗     ██╔██╗ ██║██║   ██║██║██╔████╔██║ Integrated
██║     ██║   ██║   ██╔══╝  ██╔══╝     ██║╚██╗██║╚██╗ ██╔╝██║██║╚██╔╝██║ Text
███████╗██║   ██║   ███████╗███████╗██╗██║ ╚████║ ╚████╔╝ ██║██║ ╚═╝ ██║ Editing
╚══════╝╚═╝   ╚═╝   ╚══════╝╚══════╝╚═╝╚═╝  ╚═══╝  ╚═══╝  ╚═╝╚═╝     ╚═╝ Environment
====================================================================================
```

![litee screenshot](./contrib/litee-screenshot.png)

# litee-calltree

litee-calltree utilizes the [litee.nvim](https://github.com/ldelossa/litee.nvim) library to implement a tool analogous to VSCode's
"Call Hierarchy" tool. 

This tool exposes an explorable tree of incoming or outgoing calls for a given symbol.

Unlike other Neovim plugins, the tree can be expanded and collapsed to discover "callers-of-callers" 
and "callees-of-callees" until you hit a leaf.

Like all `litee.nvim` backed plugins the UI will work with other `litee.nvim` plugins, 
keeping its appropriate place in a collapsible panel.

# Usage

## Get it

Plug:
```
 Plug 'ldelossa/litee.nvim'
 Plug 'ldelossa/litee-calltree.nvim'
```

## Set it

Call the setup function from anywhere you configure your plugins from.

Configuration dictionary is explained in ./doc/litee.txt (:h litee-config)

```
-- configure the litee.nvim library 
require('litee.lib').setup({})
-- configure litee-calltree.nvim
require('litee.calltree').setup({})
```

## Use it

litee-calltree.nvim hooks directly into the LSP infrastructure by hijacking the necessary
handlers like so:

    vim.lsp.handlers['callHierarchy/incomingCalls'] = vim.lsp.with(
                require('litee.lsp.handlers').ch_lsp_handler("from"), {}
    )
    vim.lsp.handlers['callHierarchy/outgoingCalls'] = vim.lsp.with(
                require('litee.lsp.handlers').ch_lsp_handler("to"), {}
    )

This occurs when `require('litee.calltree').setup()` is called.

Once the handlers are in place issuing the normal "vim.lsp.buf.incoming_calls" 
and "vim.lsp.buf.outgoing_calls" functions will open the Calltree UI, respectively.

All of LITEE.nvim can be controlled via commands making it possible to navigate
the Calltree via key bindings. 

Check out the help file for full details.
