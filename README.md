## Use grok 4 right within neovim! 
call grok-4-fast in a vim buffer and stream the response text into file

put this file in your custom plugins folder
~/.config/nvim/lua/custom/plugins/grok_replace.lua

tested with nvchad on mac

## nvchad.lua setup
require("custom.plugins.grok_replace").setup({ model = "grok-4-fast" })

## mappings.lua setup
map({"n", "v"}, "<leader>G", ":GrokReplace<CR>", { desc = "Grok Replace" })

## how to call the plugin 
use visual mode to select the text to replace 

I'm using leader+G to call it

based on a yacine repo




