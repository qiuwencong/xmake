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
-- @author      ruki
-- @file        build_ninja.lua
--

-- imports
import("core.project.config")
import("core.project.project")
import("core.platform.platform")
import("core.language.language")
import("core.tool.linker")
import("core.tool.compiler")
import("lib.detect.find_tool")
import("lib.detect.find_toolname")
import("private.tools.cl.parse_include")

-- this sourcebatch is built?
function _sourcebatch_is_built(sourcebatch)
    -- we can only use rulename to filter them because sourcekind may be bound to multiple rules
    local rulename = sourcebatch.rulename
    if rulename == "c.build" or rulename == "c++.build"
        or rulename == "asm.build" or rulename == "cuda.build"
        or rulename == "objc.build" or rulename == "objc++.build" then
        return true
    end
end

-- escape path
function _escape_path(filepath)
    if is_host("windows") then
        filepath = filepath:gsub('\\', '/')
    end
    return filepath
end

-- tranlate path
function _translate_path(filepath, outputdir)
    filepath = path.translate(filepath)
    if filepath == "" then
        return ""
    end
    if path.is_absolute(filepath) then
        if filepath:startswith(project.directory()) then
            return path.relative(filepath, outputdir)
        end
        return filepath
    else
        return path.relative(path.absolute(filepath), outputdir)
    end
end

-- get relative unix path
function _get_relative_unix_path(filepath, outputdir)
    filepath = _translate_path(filepath, outputdir)
    filepath = _escape_path(path.translate(filepath))
    return os.args(filepath)
end

-- translate compiler flags
function _translate_compflags(compflags, outputdir)
	local flags = {}
	local last_flag = nil;
	for _, flag in ipairs(compflags) do
		if flag == "-I" or flag == "-isystem" then
			last_flag = flag;
		else
			if last_flag == "-I" or last_flag == "-isystem" then
				flag = last_flag..flag;
			end;
			last_flag = flag;
			for _, pattern in ipairs({"[%-](I)(.*)", "[%-](isystem)(.*)"}) do
				flag = flag:gsub(pattern, function (flag, dir)
						dir = _get_relative_unix_path(dir, outputdir)
						return "-" .. flag .. dir
				end)
			end
			table.insert(flags, flag)
		end;
    end
    return flags
end

-- translate linker flags
function _translate_linkflags(linkflags, outputdir)
    local flags = {}
    for _, flag in ipairs(linkflags) do
        for _, pattern in ipairs({"[%-](L)(.*)", "[%-](F)(.*)"}) do
            flag = flag:gsub(pattern, function (flag, dir)
                dir = _get_relative_unix_path(dir, outputdir)
                return "-" .. flag .. dir
            end)
        end
        table.insert(flags, flag)
    end
    return flags
end

-- add header
function _add_header(ninjafile)
    ninjafile:print([[# this is the build file for project %s
# it is autogenerated by the xmake build system.
# do not edit by hand.
]], project.name() or "")
    ninjafile:print("ninja_required_version = 1.5.1")
    ninjafile:print("")
end

-- add rules for generator
function _add_rules_for_generator(ninjafile, outputdir)
    local projectdir = _get_relative_unix_path(os.projectdir(), outputdir)
    ninjafile:print("rule gen")
    ninjafile:print(" command = xmake project -P %s -k ninja", projectdir)
    ninjafile:print(" description = regenerating ninja files")
    ninjafile:print("")
end

-- add rules for complier (gcc)
function _add_rules_for_compiler_gcc(ninjafile, sourcekind, program)
    local ccache = config.get("ccache") ~= false and find_tool("ccache")
    ninjafile:print("rule %s", sourcekind)
    ninjafile:print(" command = %s%s $ARGS -MMD -MF $out.d -o $out -c $in", ccache and (ccache.program .. " ") or "", program)
    ninjafile:print(" deps = gcc")
    ninjafile:print(" depfile = $out.d")
    ninjafile:print(" description = %scompiling.%s $in", ccache and "ccache " or "", config.mode())
    ninjafile:print("")
end

-- add rules for complier (clang)
function _add_rules_for_compiler_clang(ninjafile, sourcekind, program)
    return _add_rules_for_compiler_gcc(ninjafile, sourcekind, program)
end

-- add rules for complier (msvc/cl)
function _add_rules_for_compiler_msvc_cl(ninjafile, sourcekind, program)
    ninjafile:print("rule %s", sourcekind)
    ninjafile:print(" command = %s -showIncludes -c $ARGS $in -Fo$out", program)
    ninjafile:print(" deps = msvc")
    ninjafile:print(" description = compiling.%s $in", config.mode())
    ninjafile:print("")
end

-- add rules for complier (msvc/ml)
function _add_rules_for_compiler_msvc_ml(ninjafile, sourcekind, program)
    ninjafile:print("rule %s", sourcekind)
    ninjafile:print(" command = %s -c $ARGS -Fo$out $in", program)
    ninjafile:print(" deps = msvc")
    ninjafile:print(" description = compiling.%s $in", config.mode())
    ninjafile:print("")
end

-- add rules for resource complier (msvc/rc)
function _add_rules_for_compiler_msvc_rc(ninjafile, sourcekind, program)
    ninjafile:print("rule %s", sourcekind)
    ninjafile:print(" command = %s $ARGS -Fo$out $in", program)
    ninjafile:print(" deps = msvc")
    ninjafile:print(" description = compiling.%s $in", config.mode())
    ninjafile:print("")
end

-- add rules for resource complier (windres/rc)
function _add_rules_for_compiler_windres(ninjafile, sourcekind, program)
    ninjafile:print("rule %s", sourcekind)
    ninjafile:print(" command = %s $ARGS $in $out", program)
    ninjafile:print(" description = compiling.%s $in", config.mode())
    ninjafile:print("")
end

-- add rules for complier
function _add_rules_for_compiler(ninjafile)
    ninjafile:print("# rules for compiler")
    if is_plat("windows") then
        -- @see https://github.com/ninja-build/ninja/issues/613
        local note_include = parse_include.probe_include_note_from_cl()
        if not note_include then
            note_include = "Note: including file:"
        end
        ninjafile:print("msvc_deps_prefix = %s", note_include:trim())
    end
    local add_compiler_rules =
    {
        gcc     = _add_rules_for_compiler_gcc,
        gxx     = _add_rules_for_compiler_gcc,
        clang   = _add_rules_for_compiler_clang,
        clangxx = _add_rules_for_compiler_clang,
        cl      = _add_rules_for_compiler_msvc_cl,
        ml      = _add_rules_for_compiler_msvc_ml,
        ml64    = _add_rules_for_compiler_msvc_ml,
        rc      = _add_rules_for_compiler_msvc_rc,
        windres = _add_rules_for_compiler_windres
    }
    for sourcekind, _ in pairs(language.sourcekinds()) do
        local program, toolname = platform.tool(sourcekind)
        if program then
            local add_rule = add_compiler_rules[toolname or find_toolname(program)]
            -- support of unknown compiler (xmake f --cc=gcc@my-cc)
            if not add_rule and toolname then
                add_rule = add_compiler_rules[find_toolname(toolname)]
            end
            if add_rule then
                add_rule(ninjafile, sourcekind, program)
            end
        end
    end
    ninjafile:print("")
end

-- add rules for linker (ar)
function _add_rules_for_linker_ar(ninjafile, linkerkind, program)
    ninjafile:print("rule %s", linkerkind)
    ninjafile:print(" command = %s $ARGS $out $in", program)
    ninjafile:print(" description = archiving.%s $out", config.mode())
    ninjafile:print("")
end

-- add rules for linker (gcc)
function _add_rules_for_linker_gcc(ninjafile, linkerkind, program)
    ninjafile:print("rule %s", linkerkind)
    ninjafile:print(" command = %s -o $out $in $ARGS", program)
    ninjafile:print(" description = linking.%s $out", config.mode())
    ninjafile:print("")
end

-- add rules for linker (clang)
function _add_rules_for_linker_clang(ninjafile, linkerkind, program)
    return _add_rules_for_linker_gcc(ninjafile, linkerkind, program)
end

-- add rules for linker (msvc)
function _add_rules_for_linker_msvc(ninjafile, linkerkind, program)
    if linkerkind == "ar" then
        program = program .. " -lib"
    elseif linkerkind == "sh" then
        program = program .. " -dll"
    end
    -- @note we use rspfile to handle long command limit on windows
    ninjafile:print("rule %s", linkerkind)
    ninjafile:print(" command = %s @$out.rsp", program)
    ninjafile:print(" rspfile = $out.rsp")
    ninjafile:print(" rspfile_content = $ARGS -out:$out $in_newline")
    ninjafile:print(" description = linking.%s $out", config.mode())
    ninjafile:print("")
end

-- add rules for linker
function _add_rules_for_linker(ninjafile)
    ninjafile:print("# rules for linker")
    local linkerkinds = {}
    for _, _linkerkinds in pairs(language.targetkinds()) do
        table.join2(linkerkinds, _linkerkinds)
    end
    local add_linker_rules =
    {
        ar      = _add_rules_for_linker_ar,
        gcc     = _add_rules_for_linker_gcc,
        gxx     = _add_rules_for_linker_gcc,
        clang   = _add_rules_for_linker_clang,
        clangxx = _add_rules_for_linker_clang,
        link    = _add_rules_for_linker_msvc
    }
    for _, linkerkind in ipairs(table.unique(linkerkinds)) do
        local program, toolname = platform.tool(linkerkind)
        if program then
            local add_rule = add_linker_rules[toolname or find_toolname(program)]
            -- support of unknown linker (xmake f --ld=gcc@my-ld)
            if not add_rule and toolname then
                add_rule = add_linker_rules[find_toolname(toolname)]
            end
            if add_rule then
                add_rule(ninjafile, linkerkind, program)
            end
        end
    end
    ninjafile:print("")
end

-- add rules
function _add_rules(ninjafile, outputdir)

    -- add rules for generator
    _add_rules_for_generator(ninjafile, outputdir)

    -- add rules for complier
    _add_rules_for_compiler(ninjafile)

    -- add rules for linker
    _add_rules_for_linker(ninjafile)
end

-- add build rule for phony
function _add_build_for_phony(ninjafile, target)
    ninjafile:print("build %s: phony", target:name())
end

-- add build rule for object
function _add_build_for_object(ninjafile, target, sourcekind, sourcefile, objectfile, outputdir)
    objectfile = _get_relative_unix_path(objectfile, outputdir)
    sourcefile = _get_relative_unix_path(sourcefile, outputdir)
    local compflags = compiler.compflags(sourcefile, {target = target})
    ninjafile:print("build %s: %s %s", objectfile, sourcekind, sourcefile)
    ninjafile:print(" ARGS = %s", os.args(_translate_compflags(compflags, outputdir)))
    ninjafile:print("")
end

-- add build rule for objects
function _add_build_for_objects(ninjafile, target, sourcebatch, outputdir)
    for index, objectfile in ipairs(sourcebatch.objectfiles) do
        _add_build_for_object(ninjafile, target,  sourcebatch.sourcekind, sourcebatch.sourcefiles[index], objectfile, outputdir)
    end
end

-- add build rule for target
function _add_build_for_target(ninjafile, target, outputdir)

    -- https://github.com/xmake-io/xmake/issues/2337
    target:data_set("plugin.project.kind", "ninja")

    -- is phony target?
    if target:is_phony() then
        return _add_build_for_phony(ninjafile, target)
    end

    -- build target
    ninjafile:print("# build target: %s", target:name())
    local targetfile = _get_relative_unix_path(target:targetfile(), outputdir)
    ninjafile:print("build %s: phony %s", target:name(), targetfile)

    -- build target file
    ninjafile:printf("build %s: %s", targetfile, target:linker():kind())
    local objectfiles = target:objectfiles()
    for _, objectfile in ipairs(objectfiles) do
        ninjafile:write(" " .. _get_relative_unix_path(objectfile, outputdir))
    end
    -- merge objects with rule("utils.merge.object")
    for _, sourcebatch in pairs(target:sourcebatches()) do
        if sourcebatch.rulename == "utils.merge.object" then
            ninjafile:write(" " .. table.concat(sourcebatch.sourcefiles, " "))
        end
    end
    local deps = target:get("deps")
    if deps then
        ninjafile:print(" || $")
        ninjafile:write("  ")
        for _, dep in ipairs(deps) do
            ninjafile:write(" " .. _get_relative_unix_path(project.target(dep):targetfile(), outputdir))
        end
    end
    ninjafile:print("")
    ninjafile:print(" ARGS = %s", os.args(_translate_linkflags(target:linkflags(), outputdir)))
    ninjafile:print("")

    -- build target objects
    for _, sourcebatch in table.orderpairs(target:sourcebatches()) do
        if _sourcebatch_is_built(sourcebatch) then
            _add_build_for_objects(ninjafile, target, sourcebatch, outputdir)
        end
    end
end

-- add build rule for generator
function _add_build_for_generator(ninjafile, outputdir)
    ninjafile:print("# build build.ninja")
    ninjafile:print("build build.ninja: gen $")
    local allfiles = project.allfiles()
    for idx, projectfile in ipairs(allfiles) do
        if not path.is_absolute(projectfile) or projectfile:startswith(os.projectdir()) then
            local filepath = _get_relative_unix_path(projectfile, outputdir)
            ninjafile:print("  %s %s", filepath, idx < #allfiles and "$" or "")
        end
    end
    ninjafile:print("")
end

-- add build rule for targets
function _add_build_for_targets(ninjafile, outputdir)

    -- begin
    ninjafile:print("# build targets\n")

    -- add build rule for generator
    _add_build_for_generator(ninjafile, outputdir)

    -- TODO
    -- disable precompiled header first
    for _, target in pairs(project.targets()) do
        target:set("pcheader", nil)
        target:set("pcxxheader", nil)
    end

    -- build targets
    for _, target in pairs(project.targets()) do
        _add_build_for_target(ninjafile, target, outputdir)
    end

    -- build default
    local default = ""
    for targetname, target in pairs(project.targets()) do
        if target:is_default() then
            default = default .. " " .. targetname
        end
    end
    ninjafile:print("build default: phony%s", default)

    -- build all
    local all = ""
    for targetname, _ in pairs(project.targets()) do
        all = all .. " " .. targetname
    end
    ninjafile:print("build all: phony%s\n", all)

    -- end
    ninjafile:print("default default\n")
end

function make(outputdir)

    -- enter project directory
    local oldir = os.cd(os.projectdir())

    -- open the build.ninja file
    --
    -- we need change encoding to support msvc_deps_prefix
    -- @see https://github.com/ninja-build/ninja/issues/613
    --
    -- TODO maybe we need support more encoding for other languages
    --
    local encoding = is_subhost("windows") and "gbk"
    local ninjafile = io.open(path.join(outputdir, "build.ninja"), "w", {encoding = encoding})

    -- add header
    _add_header(ninjafile)

    -- add rules
    _add_rules(ninjafile, outputdir)

    -- add build rules for targets
    _add_build_for_targets(ninjafile, outputdir)

    -- close the ninjafile
    ninjafile:close()

    -- leave project directory
    os.cd(oldir)
end
