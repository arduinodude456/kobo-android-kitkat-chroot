-- SPDX-License-Identifier: MIT
local InputContainer = require("ui/widget/container/inputcontainer")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local TextViewer = require("ui/widget/textviewer")
local Android = InputContainer:extend{name="kobo_android",is_doc_only=false}
function Android:init() self.ui.menu:registerToMainMenu(self) end
local function base_dir() return os.getenv("KOBO_ANDROID_DIR") or "/mnt/onboard/.adds/android" end
local function read_file(path)
    local f = io.open(path, "rb"); if not f then return "(keine Datei: " .. path .. ")" end
    local s = f:read("*a") or ""; f:close(); return s
end
function Android:addToMainMenu(items)
    items.kobo_android_diag={text="Android-Diagnose (Stufentest)",sorting_hint="tools",callback=function()
        UIManager:show(InfoMessage:new{text="Stufentest laeuft (ca. 20-40 s) ...",timeout=2})
        UIManager:nextTick(function()
            os.execute("sh '"..base_dir().."/android.sh' stages >/dev/null 2>&1")
            local text = read_file(base_dir().."/stages.log")
            UIManager:show(TextViewer:new{title="Stufentest",text=text,width=require("device").screen:getWidth(),height=require("device").screen:getHeight()})
        end)
    end}
    items.kobo_android={text="Android KitKat 4.4 (Chroot)",sorting_hint="tools",callback=function()
        local base=os.getenv("KOBO_ANDROID_DIR") or "/mnt/onboard/.adds/android"
        local ok,module=pcall(dofile,base.."/lua/appdock_android.lua")
        if not ok then UIManager:show(InfoMessage:new{text="Android-Modul konnte nicht geladen werden:\n"..tostring(module)}); return end
        module.open()
    end}
end
return Android
