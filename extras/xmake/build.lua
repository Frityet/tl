import("core.base.option")
import("core.project.depend")
import("lib.detect.find_tool")

local function luajit()
   local tool = assert(find_tool("luajit"), "Teal requires LuaJIT 2.1 or later on PATH")
   return tool.program
end

local function outputdir(target)
   return path.absolute(path.join(target:autogendir(), "rules", "tl", "lua"), os.projectdir())
end

local function depfile(target)
   return path.join(target:dependir(), "tl.d")
end

local function lua_path(roots, inherited, with_init)
   local entries = {}
   for _, root in ipairs(roots) do
      table.insert(entries, path.join(root, "?.lua"))
      if with_init then
         table.insert(entries, path.join(root, "?/init.lua"))
      end
   end
   table.insert(entries, inherited)
   return table.concat(entries, ";")
end

local function runtime_roots(target)
   local roots = { outputdir(target) }
   for _, dep in ipairs(target:orderdeps()) do
      local dir = dep:data("tl.outputdir")
      if dir then
         table.insert(roots, dir)
      end
   end
   return roots
end

local function inputs_and_outputs(root, files)
   local inputs, outputs = {}, {}
   for _, file in ipairs(files) do
      if not file:endswith(".d.tl") then
         local relative = path.relative(file, root)
         assert(not path.is_absolute(relative) and not relative:startswith(".." .. path.sep()),
            "%s is outside the Teal source root %s. Set tl.root to a common directory.", file, root)
         table.insert(inputs, file)
         table.insert(outputs, (relative:gsub("%.tl$", ".lua")))
      end
   end
   table.sort(inputs)
   return inputs, outputs
end

local function build(target, outputs, files, values, generate)
   local dir = outputdir(target)
   local missing = not os.isdir(dir)
   for _, file in ipairs(outputs) do
      if not os.isfile(path.join(dir, file)) then
         missing = true
         break
      end
   end
   table.sort(files)
   files = table.unique(files)
   -- Xmake's file timestamps have second-level precision.
   local fingerprints = {}
   for _, file in ipairs(files) do
      table.insert(fingerprints, hash.sha256(file))
   end
   depend.on_changed(function()
      local stage = dir .. ".stage"
      os.rm(stage)
      os.mkdir(stage)
      cprint("${color.build.object}transpiling Teal for %s", target:name())
      generate(stage)
      for _, file in ipairs(outputs) do
         assert(os.isfile(path.join(stage, file)), "Teal did not generate %s", file)
      end
      os.rm(dir)
      os.mv(stage, dir)
   end, {
      dependfile = depfile(target),
      files = files,
      values = table.join(values, { fingerprints }),
      changed = missing or target:is_rebuilt()
   })
end

local function gen(lua, script, root, out, inputs, flags, opts)
   if #inputs > 0 then
      local args = table.join({ script, "--quiet" }, flags, {
         "gen", "--root", root, "--output-dir", out, "--"
      }, inputs)
      os.vrunv(lua, args, opts)
   end
end

function compiler(target)
   if option.get("dry-run") then return end
   local root = target:scriptdir()
   local lua = luajit()
   local sources = table.join(os.files(path.join(root, "teal/**.tl")),
      os.files(path.join(root, "tlcli/**.tl")), {
         path.join(root, "precompiler.tl"),
         path.join(root, "extras/combine.tl")
      })
   local inputs, outputs = inputs_and_outputs(root, sources)
   local bootstrap = path.join(root, "tl")
   local default_env = "teal/precompiled/default_env.lua"
   local reader_api = "teal/reader_api.lua"
   local files = table.join(sources, os.files(path.join(root, "*.tl")), {
      bootstrap, path.join(root, "teal.lua"), path.join(root, default_env),
      path.join(root, reader_api), path.join(root, "xmake.lua"),
      path.join(root, "extras/xmake/build.lua"), lua
   }, os.files(path.join(root, "tlcli/**.lua")))
   outputs = table.join(outputs, { "tl", "tl.lua", "teal.lua", default_env, reader_api })

   local env_values = { os.getenv("LUA_PATH") or false, os.getenv("LUA_CPATH") or false }
   build(target, outputs, files, env_values, function(stage)
      local envs = { TL_PATH = path.join(root, "?.lua"), PWD = stage }
      local config = path.join(stage, "tlconfig.lua")
      io.writefile(config, "return {}\n")
      gen(lua, bootstrap, root, stage, inputs, { "--gen-target=5.1" }, { curdir = stage, envs = envs })
      os.rm(config)

      -- The precompiler loads the new modules using the checked-in environment.
      local generated_env = path.join(stage, default_env)
      os.mkdir(path.directory(generated_env))
      os.cp(path.join(root, default_env), generated_env)
      os.cp(path.join(root, reader_api), path.join(stage, reader_api))
      local precompiled = os.iorunv(lua, { "precompiler.lua" }, { curdir = stage, envs = envs })
      io.writefile(generated_env, precompiled)
      os.vrunv(lua, { "extras/combine.lua", "teal.api.v2", "tl.lua" }, { curdir = stage })
      os.vrunv(lua, { "extras/combine.lua", "teal.init", "teal.lua" }, { curdir = stage })
      os.cp(bootstrap, path.join(stage, "tl"))
   end)
end

function load(target)
   local root = target:values("tl.root") or target:scriptdir()
   target:data_set("tl.root", path.absolute(root, target:scriptdir()))
   target:data_set("tl.outputdir", outputdir(target))
   target:add("deps", "tl", { inherit = false })
   target:set("policy", "build.fence", true)
end

function transpile(target)
   if option.get("dry-run") then return end
   local sourcebatch = target:sourcebatches()["tl"]
   local root = target:data("tl.root")
   local sourcefiles = sourcebatch and sourcebatch.sourcefiles or {}
   local absolute_files = {}
   for _, file in ipairs(sourcefiles) do
      table.insert(absolute_files, path.absolute(file, os.projectdir()))
   end
   local inputs, outputs = inputs_and_outputs(root, absolute_files)
   local compiler = target:dep("tl")
   local roots = { root }
   for _, dir in ipairs(table.wrap(target:values("tl.includedirs"))) do
      table.insert(roots, path.absolute(dir, target:scriptdir()))
   end
   local files = table.join(absolute_files, { depfile(compiler) })
   for _, dep in ipairs(target:orderdeps()) do
      local dep_root = dep:data("tl.root")
      if dep_root then
         table.insert(roots, dep_root)
         table.insert(files, depfile(dep))
      end
   end
   roots = table.unique(table.join(roots, compiler:scriptdir()))
   for _, dir in ipairs(roots) do
      table.join2(files, os.files(path.join(dir, "**.tl")))
   end

   local auxlib = target:name() == "tl.auxlib"
   local projectdir = os.projectdir()
   if not auxlib then
      local dir = projectdir
      for _ = 1, 20 do
         local config = path.join(dir, "tlconfig.lua")
         if os.isfile(config) then
            table.insert(files, config)
            break
         end
         local parent = path.directory(dir)
         if not parent or parent == "" or parent == dir then break end
         dir = parent
      end
   end

   local lua = luajit()
   local script = path.join(outputdir(compiler), "tl")
   local tl_path = auxlib and "" or os.getenv("TL_PATH")
   if tl_path then
      tl_path = lua_path(roots, tl_path, false)
   end
   local search_path = lua_path(table.unique(table.join(roots, runtime_roots(target))),
      os.getenv("LUA_PATH") or ";", true)
   build(target, outputs, table.join(files, lua), { search_path, tl_path or false, os.getenv("LUA_CPATH") or false },
      function(stage)
         local cwd = auxlib and stage or projectdir
         local envs = { LUA_PATH = search_path, TL_PATH = tl_path, PWD = cwd }
         local flags = {}
         if auxlib then
            local config = path.join(stage, "tlconfig.lua")
            io.writefile(config, "return {}\n")
            flags = { "--gen-target=5.1" }
         end
         gen(lua, script, root, stage, inputs, flags, { curdir = cwd, envs = envs })
         if auxlib then
            os.rm(path.join(stage, "tlconfig.lua"))
         end
      end)
end

function runenv(target)
   os.setenv("LUA_PATH", lua_path(runtime_roots(target), os.getenv("LUA_PATH") or ";", true))
end

function clean(target)
   local dir = outputdir(target)
   os.rm(dir)
   os.rm(dir .. ".stage")
   os.rm(depfile(target))
end

function run_compiler(target)
   local script = path.join(outputdir(target), "tl")
   assert(os.isfile(script), "Build the Teal compiler with xmake build tl")
   local args = table.join({ script }, table.wrap(option.get("arguments")))
   os.execv(luajit(), args, { curdir = os.projectdir(), envs = { PWD = os.projectdir() } })
end
