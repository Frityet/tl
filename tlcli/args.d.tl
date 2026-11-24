local record Args
   check: boolean
   command: string
   custom_ext: string
   dump_format: string
   entry: string
   feat_arity: string
   file: {string}
   gen_target: string
   gen_compat: string
   no_stdlib: boolean
   global_env_def: {string} -- FIXME should be `string`, but argparse can't handle `:count("0-1")`?...
   include_dir: {string}
   keep_hashbang: boolean
   no_check: boolean
   output: string
   output_dir: string
   pack_cc: string
   pack_compress: boolean
   pack_liblua: string
   pack_link_args: {string}
   pack_lua_include: string
   pack_lua_version: string
   pack_modules: {string}
   pack_native: {string}
   pack_no_precompile: boolean
   pack_no_static: boolean
   pack_precompile: boolean
   pack_static: boolean
   position: string
   pretend: boolean
   root: string
   quiet: boolean
   require: {string}
   script: {string}
   stdio: boolean
   version: boolean
   wdisable: {string}
   werror: {string}
end

return Args
