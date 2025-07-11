## Use grok 4 right within neovim! 
based on a yacine repo I saw a while back

put this file in your custom plugins folder

I'm using nvchad on macos. no idea if it's working on other setups. 

## nvchad.lua setup
require("custom.plugins.grok_replace").setup({ model = "grok-4-0709" })

## mappings.lua setup
map({"n", "v"}, "<leader>g", ":GrokReplace<CR>", { desc = "Grok Replace" })

## how to call the plugin 
use visual mode to select the text to replace 

I'm using leader+g to call it




