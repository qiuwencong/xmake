--!A cross-platform build utility based on Lua
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
-- Copyright (C) 2015-present, TBOOX Open Source Group.
--
-- @author      Arthapz, ruki
-- @file        common.lua
--

-- imports
import("core.base.json")
import("core.base.hashset")
import("core.project.config")
import("core.tool.compiler")
import("core.cache.memcache", {alias = "_memcache"})
import("core.cache.localcache", {alias = "_localcache"})
import("core.project.project")
import("lib.detect.find_file")
import("stl_headers")

-- get memcache
function memcache()
    return _memcache.cache("cxxmodules")
end

-- get localcache
function localcache()
    return _localcache.cache("cxxmodules")
end

-- get stl modules cache directory
function stlmodules_cachedir(target)
    local stlcachedir = path.join(config.buildir(), "stlmodules", "cache")
    if not os.isdir(stlcachedir) then
        os.mkdir(stlcachedir)
        os.mkdir(path.join(stlcachedir, "experimental"))
    end
    return stlcachedir
end

-- get modules cache directory
function modules_cachedir(target)
    local cachedir = path.join(target:autogendir(), "rules", "modules", "cache")
    if not os.isdir(cachedir) then
        os.mkdir(cachedir)
    end
    return cachedir
end

-- get headerunits info
function get_headerunits(target, sourcebatch, modules)
    local headerunits
    local stl_headerunits
    for _, objectfile in ipairs(sourcebatch.objectfiles) do
        local m = modules[objectfile]
        if m then
            for name, r in pairs(m.requires) do
                if r.method ~= "by-name" then
                    local unittype = r.method == "include-angle" and ":angle" or ":quote"
                    if stl_headers.is_stl_header(name) then
                        stl_headerunits = stl_headerunits or {}
                        if not table.find_if(stl_headerunits, function(i, v) return v.name == name end) then
                            table.insert(stl_headerunits, {name = name, path = r.path, type = unittype})
                        end
                    else
                        headerunits = headerunits or {}
                        if not table.find_if(headerunits, function(i, v) return v.name == name end) then
                            table.insert(headerunits, {name = name, path = r.path, type = unittype})
                        end
                    end
                end
            end
        end
    end
    return headerunits, stl_headerunits
end

-- patch sourcebatch
function patch_sourcebatch(target, sourcebatch)
    local cachedir = modules_cachedir(target)
    sourcebatch.sourcekind = "cxx"
    sourcebatch.objectfiles = {}
    sourcebatch.dependfiles = {}
    for _, sourcefile in ipairs(sourcebatch.sourcefiles) do
        local objectfile = target:objectfile(sourcefile)
        local dependfile = target:dependfile(objectfile)
        table.insert(sourcebatch.objectfiles, objectfile)
        table.insert(sourcebatch.dependfiles, dependfile)
    end
end

-- get modules support
function modules_support(target)
    local cachekey = tostring(target)
    local module_builder = memcache():get2("modules_support", cachekey)
    if module_builder == nil then
        if target:has_tool("cxx", "clang", "clangxx") then
            module_builder = import("clang", {anonymous = true})
        elseif target:has_tool("cxx", "gcc", "gxx") then
            module_builder = import("gcc", {anonymous = true})
        elseif target:has_tool("cxx", "cl") then
            module_builder = import("msvc", {anonymous = true})
        else
            local _, toolname = target:tool("cxx")
            raise("compiler(%s): does not support c++ module!", toolname)
        end
        memcache():set2("modules_support", cachekey, module_builder)
    end
    return module_builder
end

-- get bmi extension
function bmi_extension(target)
    return modules_support(target).get_bmi_extension()
end

-- this target contains module files?
function contains_modules(target)
    local target_with_modules = target:sourcebatches()["c++.build.modules"] and true or false
    if not target_with_modules then
        for _, dep in ipairs(target:orderdeps()) do
            local sourcebatches = dep:sourcebatches()
            if sourcebatches and sourcebatches["c++.build.modules"] then
                target_with_modules = true
                break
            end
        end
    end
    return target_with_modules
end

-- load module infos
function load_moduleinfos(target, sourcebatch)
    local moduleinfos
    for _, sourcefile in ipairs(sourcebatch.sourcefiles) do
        local dependfile = target:dependfile(sourcefile)
        if os.isfile(dependfile) then
            local data = io.load(dependfile)
            if data then
                moduleinfos = moduleinfos or {}
                local moduleinfo = json.decode(data.moduleinfo)
                moduleinfo.sourcefile = sourcefile
                if moduleinfo then
                    table.insert(moduleinfos, moduleinfo)
                end
            end
        end
    end
    return moduleinfos
end

-- parse module dependency data
--[[
{
  "build/.objs/stl_headerunit/linux/x86_64/release/src/hello.mpp.o" = {
    requires = {
      iostream = {
        method = "include-angle",
        unique = true,
        path = "/usr/include/c++/11/iostream"
      }
    },
    provides = {
      hello = {
        bmi = "build/.gens/stl_headerunit/linux/x86_64/release/rules/modules/cache/hello.gcm",
        sourcefile = "src/hello.mpp"
      }
    }
  },
  "build/.objs/stl_headerunit/linux/x86_64/release/src/main.cpp.o" = {
    requires = {
      hello = {
        method = "by-name",
        unique = false,
        path = "build/.gens/stl_headerunit/linux/x86_64/release/rules/modules/cache/hello.gcm"
      }
    }
  }
}]]
function parse_dependency_data(target, moduleinfos)
    local modules
    local cachedir = modules_cachedir(target)
    for _, moduleinfo in ipairs(moduleinfos) do
        assert(moduleinfo.version <= 1)
        for _, rule in ipairs(moduleinfo.rules) do
            modules = modules or {}
            local m = {}
            for _, provide in ipairs(rule.provides) do
                m.provides = m.provides or {}
                assert(provide["logical-name"])
                if provide["compiled-module-path"] then
                    if not path.is_absolute(provide["compiled-module-path"]) then
                        m.provides[provide["logical-name"]] = path.absolute(path.translate(provide["compiled-module-path"]))
                    else
                        m.provides[provide["logical-name"]] = path.translate(provide["compiled-module-path"])
                    end
                else
                    -- assume path with name
                    local name = provide["logical-name"] .. bmi_extension(target)
                    name:replace(":", "-")
                    m.provides[provide["logical-name"]] = {
                        bmi = path.join(cachedir, name),
                        sourcefile = moduleinfo.sourcefile
                    }
                end
            end
            assert(rule["primary-output"])
            modules[path.translate(rule["primary-output"])] = m
        end
    end

    for _, moduleinfo in ipairs(moduleinfos) do
        for _, rule in ipairs(moduleinfo.rules) do
            local m = modules[path.translate(rule["primary-output"])]
            for _, r in ipairs(rule.requires) do
                m.requires = m.requires or {}
                local p = r["source-path"]
                if not p then
                    for _, dependency in pairs(modules) do
                        if dependency.provides and dependency.provides[r["logical-name"]] then
                            p = dependency.provides[r["logical-name"]].bmi
                            break
                        end
                    end
                end
                m.requires[r["logical-name"]] = {
                    method = r["lookup-method"] or "by-name",
                    path = p and path.translate(p) or nil,
                    unique = r["unique-on-source-path"] or false
                }
            end
        end
    end
    return modules
end

function _topological_sort_visit(node, nodes, modules, output)
    if node.marked then
        return
    end
    assert(not node.tempmarked)
    node.tempmarked = true
    local m1 = modules[node.objectfile]
    assert(m1 and m1.provides)
    for _, n in ipairs(nodes) do
        if not n.tempmarked then
            local m2 = modules[n.objectfile]
            if m2 then
                for name, provide in pairs(m1.provides) do
                    if m2.requires and m2.requires[name] then
                        _topological_sort_visit(n, nodes, modules, output)
                    end
                end
            end
        end
    end
    node.tempmarked = false
    node.marked = true
    table.insert(output, 1, node.objectfile)
end

function _topological_sort_has_node_without_mark(nodes)
    for _, node in ipairs(nodes) do
        if not node.marked then
            return true
        end
    end
    return false
end

function _topological_sort_get_first_unmarked_node(nodes)
    for _, node in ipairs(nodes) do
        if not node.marked and not node.tempmarked then
            return node
        end
    end
end

-- topological sort
function sort_modules_by_dependencies(objectfiles, modules)
    local output = {}
    local nodes  = {}
    for _, objectfile in ipairs(objectfiles) do
        local m = modules[objectfile]
        if m and m.provides then
            table.insert(nodes, {marked = false, tempmarked = false, objectfile = objectfile})
        end
    end
    while _topological_sort_has_node_without_mark(nodes) do
        local node = _topological_sort_get_first_unmarked_node(nodes)
        _topological_sort_visit(node, nodes, modules, output)
    end
    return output
end

function find_quote_header_file(target, sourcefile, file)
    local p = path.join(path.directory(path.absolute(sourcefile, project.directory())), file)
    assert(os.isfile(p))
    return p
end

function find_angle_header_file(target, file)
    local headerpaths = modules_support(target).toolchain_includedirs(target)
    for _, dep in ipairs(target:orderdeps()) do
        local includedirs = dep:get("sysincludedirs") or dep:get("includedirs")
        if includedirs then
            table.join2(headerpaths, includedirs)
        end
    end
    for _, pkg in pairs(target:pkgs()) do
        local includedirs = pkg:get("sysincludedirs") or pkg:get("includedirs")
        if includedirs then
            table.join2(headerpaths, includedirs)
        end
    end
    table.join2(headerpaths, target:get("includedirs"))
    local p = find_file(file, headerpaths)
    assert(p, "find <%s> not found!", file)
    return p
end

-- https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2022/p1689r5.html
--[[
{
  "version": 1,
  "revision": 0,
  "rules": [
    {
      "primary-output": "use-header.mpp.o",
      "requires": [
        {
          "logical-name": "<header.hpp>",
          "source-path": "/path/to/found/header.hpp",
          "unique-on-source-path": true,
          "lookup-method": "include-angle"
        }
      ]
    },
    {
      "primary-output": "header.hpp.bmi",
      "provides": [
        {
          "logical-name": "header.hpp",
          "source-path": "/path/to/found/header.hpp",
          "unique-on-source-path": true,
        }
      ]
    }
  ]
}]]
function fallback_generate_dependencies(target, jsonfile, sourcefile)
    local output = {version = 0, revision = 0, rules = {}}
    local rule = {outputs = {jsonfile}}
    rule["primary-output"] = target:objectfile(sourcefile)

    local module_name
    local module_deps = {}
    local sourcecode = io.readfile(sourcefile)
    sourcecode = sourcecode:gsub("//.-\n", "\n")
    sourcecode = sourcecode:gsub("/%*.-%*/", "")
    for _, line in ipairs(sourcecode:split("\n", {plain = true})) do
        if not module_name then
            module_name = line:match("export%s+module%s+(.+)%s*;")
        end
        local module_depname = line:match("import%s+(.+)%s*;")
        if module_depname then
            local module_dep = {}
            -- partition? import :xxx;
            if module_depname:startswith(":") then
                module_depname = module_name .. module_depname
            elseif module_depname:startswith("\"") then
                module_depname = module_depname:sub(2, -2)
                module_dep["lookup-method"] = "include-quote"
                module_dep["unique-on-source-path"] = true
                module_dep["source-path"] = find_quote_header_file(target, sourcefile, module_depname)
            elseif module_depname:startswith("<") then
                module_depname = module_depname:sub(2, -2)
                module_dep["lookup-method"] = "include-angle"
                module_dep["unique-on-source-path"] = true
                module_dep["source-path"] = find_angle_header_file(target, module_depname)
            end
            module_dep["logical-name"] = module_depname
            table.insert(module_deps, module_dep)
        end
    end

    if module_name then
        table.insert(rule.outputs, module_name .. bmi_extension(target))

        local provide = {}
        provide["logical-name"] = module_name
        provide["source-path"] = path.absolute(sourcefile, project.directory())

        rule.provides = {}
        table.insert(rule.provides, provide)
    end

    rule.requires = module_deps
    table.insert(output.rules, rule)
    local jsondata = json.encode(output)
    io.writefile(jsonfile, jsondata)
end

-- generate dependencies
function generate_dependencies(target, sourcebatch, opt)
    local modules = localcache():get("modules")
    local changed = modules_support(target).generate_dependencies(target, sourcebatch, opt)
    if changed or modules == nil then
        local moduleinfos = load_moduleinfos(target, sourcebatch)
        modules = parse_dependency_data(target, moduleinfos)
        localcache():set("modules", modules)
        localcache():save()
    end
    return modules
end

-- generate headerunits for batchjobs, TODO
function generate_headerunits_for_batchjobs(target, batchjobs, sourcebatch, modules, opt)

    -- get headerunits info
    local headerunits, stl_headerunits = get_headerunits(target, sourcebatch, modules)

    -- generate headerunits
    -- build stl header units as other headerunits may need them
    local headerunits_flags
    if stl_headerunits then
        headerunits_flags = headerunits_flags or {}
--        table.join2(headerunits_flags, modules_support(target).generate_stl_headerunits_for_batchjobs(target, batchjobs, stl_headerunits, opt))
    end
    if headerunits then
        headerunits_flags = headerunits_flags or {}
--        table.join2(headerunits_flags, modules_support(target).generate_user_headerunits_for_batchjobs(target, batchjobs, headerunits, opt))
    end
    return headerunits_flags
end

-- generate headerunits for batchcmds
function generate_headerunits_for_batchcmds(target, batchcmds, sourcebatch, modules, opt)

    -- get headerunits info
    local user_headerunits, stl_headerunits = get_headerunits(target, sourcebatch, modules)

    -- generate headerunits
    -- build stl header units as other headerunits may need them
    if stl_headerunits or user_headerunits then
        local headerunits_flags = localcache():get("headerunits_flags")
        if stl_headerunits then
            modules_support(target).generate_stl_headerunits_for_batchcmds(target, batchcmds, stl_headerunits, opt)
        table.join2(headerunits_flags, modules_support(target).generate_stl_headerunits_for_batchcmds(target, batchcmds, stl_headerunits, opt))
        end
        if user_headerunits then
            modules_support(target).generate_user_headerunits_for_batchcmds(target, batchcmds, user_headerunits, opt)
        end
    end
    return headerunits_flags
end

-- build modules for batchjobs, TODO
function build_modules_for_batchjobs(target, batchjobs, sourcebatch, modules, opt)
    local objectfiles = sort_modules_by_dependencies(sourcebatch.objectfiles, modules)
--    modules_support(target).build_modules_for_batchjobs(target, batchjobs, objectfiles, modules, opt)
end

-- build modules for batchcmds
function build_modules_for_batchcmds(target, batchcmds, sourcebatch, modules, opt)
    local objectfiles = sort_modules_by_dependencies(sourcebatch.objectfiles, modules)
    modules_support(target).build_modules_for_batchcmds(target, batchcmds, objectfiles, modules, opt)
end

