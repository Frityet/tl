-- Run the freshly built modules without preloading an older compiler bundle.
package.path = "./?.lua;./?/init.lua;" .. package.path
require("teal.api.v1")
require("tlcli.main")({...})
