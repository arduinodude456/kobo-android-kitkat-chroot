-- SPDX-License-Identifier: MIT
local InputContainer = require("ui/widget/container/inputcontainer")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local Android = InputContainer:extend{name="kobo_android",is_doc_only=false}
function Android:init() self.ui.menu:registerToMainMenu(self) end
function Android:addToMainMenu(items)
    items.kobo_android={text="Android 4.4 (Chroot)",sorting_hint="tools",callback=function()
        local base=os.getenv("KOBO_ANDROID_DIR") or "/mnt/onboard/.adds/android"
        local ok,module=pcall(dofile,base.."/lua/appdock_android.lua")
        if not ok then UIManager:show(InfoMessage:new{text="Android-Modul konnte nicht geladen werden:\n"..tostring(module)}); return end
        module.open()
    end}
end
return Android
