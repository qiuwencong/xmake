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
-- @file        xmake.lua
--

-- add *.def for windows/dll
rule("platform.windows.def")
    set_extensions(".def")
    on_config("windows", "mingw", function (target)
        if not target:is_shared() then
            return
        end

        local sourcebatch = target:sourcebatches()["platform.windows.def"]
        if sourcebatch then
            for _, sourcefile in ipairs(sourcebatch.sourcefiles) do
                if target:is_plat("windows") then
                    target:add("shflags", "/def:" .. path.translate(sourcefile), {force = true})
                    break;
                elseif target:is_plat("mingw") then
                    target:add("shflags", path.translate(sourcefile), {force = true})
                    break;
                end
            end
        end
    end)

