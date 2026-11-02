-- SPDX-License-Identifier: MIT
-- Android Lollipop through a loopback-only RFB 3.8 connection. No external viewer.
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local ffi = require("ffi")
local socket = require("socket")
local Screen = Device.screen
local BASE = os.getenv("KOBO_ANDROID_DIR") or "/mnt/onboard/.adds/android"
local HOST, PORT = "127.0.0.1", 5963
local function quote(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
local function exists(path) local f = io.open(path, "rb"); if f then f:close(); return true end; return false end
local function command(arg) return "sh " .. quote(BASE .. "/android.sh") .. " " .. arg end
local function tail_file(path, limit)
    local f = io.open(path, "rb")
    if not f then return "" end
    local n = f:seek("end") or 0; f:seek("set", math.max(0, n - limit))
    local s = f:read("*a") or ""; f:close(); return s
end
local function diagnostics()
    local log = tail_file(BASE .. "/android.log", 1800)
    local init = tail_file(BASE .. "/android-init.log", 1200)
    if log == "" then log = "Kein android.log vorhanden." end
    if init ~= "" then log = log .. "\n\n--- android-init.log ---\n" .. init end
    return log
end
local function recover_stale_state()
    -- recover is conservative: active Android processes are never killed.
    os.execute("(" .. command("recover") .. ") >/dev/null 2>&1")
end
local function u16(s, i) local a,b=s:byte(i,i+1); return a*256+b end
local function u32(s, i) local a,b,c,d=s:byte(i,i+3); return ((a*256+b)*256+c)*256+d end
local function p16(v) return string.char(math.floor(v/256)%256, v%256) end
local function p32(v) return p16(math.floor(v/65536)%65536)..p16(v%65536) end
local RFB = {}; RFB.__index = RFB
function RFB:send(s)
    -- Only tiny control packets. A blocked/closed local peer is an error, not a UI hang.
    self.sock:settimeout(0.2)
    local n, err = self.sock:send(s)
    self.sock:settimeout(0)
    if n ~= #s then error("RFB senden: " .. tostring(err)) end
end
function RFB:read(n)
    local data, err = self.sock:receive(n)
    if not data then error("RFB Handshake: " .. tostring(err)) end
    return data
end
function RFB.connect()
    local s = assert(socket.tcp())
    s:settimeout(0.35)
    local ok, err = s:connect(HOST, PORT)
    if not ok then s:close(); return nil, err end
    local self = setmetatable({sock=s, buf="", rects=nil}, RFB)
    local success, why = pcall(function()
        s:settimeout(1)
        assert(self:read(12) == "RFB 003.008\n", "RFB-Version wird nicht unterstützt")
        assert(s:send("RFB 003.008\n"))
        local n = self:read(1):byte(); assert(n > 0 and n <= 16, "RFB Security")
        local types = self:read(n); assert(types:find("\1", 1, true), "Nur lokales RFB ohne Auth wird unterstützt")
        assert(s:send("\1")); assert(u32(self:read(4),1)==0, "RFB verweigert")
        assert(s:send("\1"))
        local init = self:read(24)
        self.w, self.h = u16(init,1), u16(init,3)
        assert(self.w >= 1 and self.w <= 1024 and self.h >= 1 and self.h <= 1024, "Ungültige Bildgröße")
        assert(self.w*self.h <= 786432, "Bild ist zu groß")
        local namelen=u32(init,21); assert(namelen<=1024,"Desktopname zu lang"); self:read(namelen)
        -- KOReader RGB32 memory layout: R,G,B,alpha; raw-only, little endian.
        assert(s:send("\0\0\0\0" .. string.char(32,24,0,1) .. p16(255)..p16(255)..p16(255)..string.char(0,8,16).."\0\0\0"))
        assert(s:send("\2\0"..p16(1)..p32(0)))
        self.bb=Blitbuffer.new(self.w,self.h,Blitbuffer.TYPE_BBRGB32)
        self.bb:fill(Blitbuffer.COLOR_WHITE)
        s:settimeout(0)
        self:request(false)
    end)
    if not success then self:close(); return nil, why end
    return self
end
function RFB:close()
    if self.sock then self.sock:close(); self.sock=nil end
    if self.bb then self.bb:free(); self.bb=nil end
end
function RFB:request(incremental)
    self:send("\3"..string.char(incremental and 1 or 0)..p16(0)..p16(0)..p16(self.w)..p16(self.h))
end
function RFB:key(sym, down) self:send("\4"..string.char(down and 1 or 0).."\0\0"..p32(sym)) end
function RFB:pointer(x,y,down)
    x=math.max(0,math.min(self.w-1,math.floor(x))); y=math.max(0,math.min(self.h-1,math.floor(y)))
    self:send("\5"..string.char(down and 1 or 0)..p16(x)..p16(y))
end
function RFB:take(n)
    if #self.buf<n then return nil end
    local s=self.buf:sub(1,n); self.buf=self.buf:sub(n+1); return s
end
function RFB:poll()
    -- No blocking receive on the KOReader UI thread. Bound both memory and work.
    for _=1,4 do
        local data,err,part=self.sock:receive(32768)
        data=data or part
        if data and #data>0 then self.buf=self.buf..data end
        if #self.buf>self.w*self.h*4+65536 then error("RFB Puffergrenze überschritten") end
        if err=="closed" then error("Android-Verbindung beendet") end
        if err=="timeout" then break end
    end
    local changed=false
    for _=1,16 do
        if self.pixel_rect then
            local r=self.pixel_rect; local data=self:take(r.w*r.h*4)
            if not data then break end
            local stride=tonumber(self.bb.stride) or self.w*4
            local src=ffi.cast("const uint8_t*",data)
            for row=0,r.h-1 do
                local dst=self.bb.data+(r.y+row)*stride+r.x*4
                ffi.copy(dst,src+row*r.w*4,r.w*4)
                for col=0,r.w-1 do dst[col*4+3]=255 end
            end
            self.pixel_rect=nil; self.rects=self.rects-1; changed=true
        elseif self.rects and self.rects>0 then
            local r=self:take(12); if not r then break end
            local x,y,w,h=u16(r,1),u16(r,3),u16(r,5),u16(r,7)
            assert(u32(r,9)==0,"Unbekanntes RFB-Encoding")
            assert(w>0 and h>0 and x+w<=self.w and y+h<=self.h,"Ungültiges RFB-Rechteck")
            self.pixel_rect={x=x,y=y,w=w,h=h}
        elseif self.rects==0 then
            self.rects=nil; self:request(true)
        else
            if #self.buf<1 then break end
            local t=self.buf:byte(1)
            if t==0 then
                if #self.buf<4 then break end
                local head=self:take(4); self.rects=u16(head,3); assert(self.rects<=64,"Zu viele RFB-Rechtecke")
            elseif t==2 then self:take(1)
            elseif t==3 then
                if #self.buf<8 then break end
                local n=u32(self.buf,5); assert(n<=4096,"Zwischenablage zu groß")
                if #self.buf<8+n then break end; self:take(8+n)
            else error("Unbekannte RFB-Nachricht") end
        end
    end
    return changed
end
local View=InputContainer:extend{name="KoboAndroid",covers_fullscreen=true}
function View:init()
    self.dimen=Geom:new{x=0,y=0,w=Screen:getWidth(),h=Screen:getHeight()}
    self.ges_events={}
    for _,g in ipairs({"touch","release","tap","pan","pan_release"}) do
        self.ges_events[g]={GestureRange:new{ges=g,range=self.dimen},event="AndroidGesture"}
    end
    self.key_events={AndroidBack={{"Back"},event="AndroidBack"}}
    self.face=Font:getFace("cfont",22)
    self.status=TextWidget:new{text="Android startet. Der erste Boot kann mehrere Minuten dauern.",face=self.face,max_width=self.dimen.w-40}
    self.buttons={}
    local defs={{"Zurück",0xff1b},{"Home",0xff50},{"Menü",0xffbe},{"Beenden",false}}
    local bw=math.floor(self.dimen.w/#defs)
    for i,d in ipairs(defs) do
        self.buttons[i]={label=TextWidget:new{text=d[1],face=self.face},key=d[2],rect=Geom:new{x=(i-1)*bw,y=self.dimen.h-90,w=bw,h=90}}
    end
    recover_stale_state()
    os.execute(command("start") .. " >/dev/null 2>&1")
    self.deadline=socket.gettime()+180
    self.tick=function() self:pollAndroid() end
    UIManager:scheduleIn(0.5,self.tick)
end
function View:paintTo(bb,x,y)
    bb:paintRect(x,y,self.dimen.w,self.dimen.h,Blitbuffer.COLOR_WHITE)
    if self.rfb then bb:blitFrom(self.rfb.bb,x+self.ox,y+self.oy,0,0,self.rfb.w,self.rfb.h)
    else self.status:paintTo(bb,x+20,y+40) end
    for _,b in ipairs(self.buttons) do
        local r=b.rect; bb:paintRect(x+r.x,y+r.y,r.w-2,r.h,Blitbuffer.COLOR_BLACK)
        bb:paintRect(x+r.x+2,y+r.y+2,r.w-6,r.h-4,Blitbuffer.COLOR_WHITE)
        local sz=b.label:getSize(); b.label:paintTo(bb,x+r.x+math.floor((r.w-sz.w)/2),y+r.y+30)
    end
end
function View:fail(text)
    UIManager:close(self,"full")
    UIManager:show(InfoMessage:new{text=text .. "\n\n" .. diagnostics()})
end
function View:pollAndroid()
    if self.closed then return end
    if not self.rfb then
        local rfb=RFB.connect()
        if rfb then
            if rfb.w>self.dimen.w or rfb.h>self.dimen.h-100 then rfb:close(); self:fail("600×800-Ansicht passt nicht. Bitte Hochformat verwenden."); return end
            self.rfb=rfb; self.ox=math.floor((self.dimen.w-rfb.w)/2); self.oy=math.floor((self.dimen.h-100-rfb.h)/2)
            UIManager:setDirty(self,"full")
        elseif socket.gettime()>self.deadline then self:fail("Android konnte nicht gestartet werden."); return end
    else
        local ok,changed=pcall(self.rfb.poll,self.rfb)
        if not ok then self:fail(tostring(changed)); return end
        if changed then UIManager:setDirty(self,"ui",Geom:new{x=self.ox,y=self.oy,w=self.rfb.w,h=self.rfb.h}) end
    end
    UIManager:scheduleIn(0.15,self.tick)
end
function View:pulse(key)
    if not self.rfb then return end
    local r=self.rfb; local ok,err=pcall(r.key,r,key,true)
    if not ok then self:fail(tostring(err)); return end
    local cb
    cb=function()
        self.key_timers[cb]=nil
        if not self.closed and self.rfb==r then pcall(r.key,r,key,false) end
    end
    self.key_timers=self.key_timers or {}; self.key_timers[cb]=true; UIManager:scheduleIn(0.12,cb)
end
function View:onAndroidBack() self:pulse(0xff1b); return true end
function View:onAndroidGesture(_,ges)
    if self.closed then return true end
    local pos=ges.pos
    if not pos then return true end
    local kind=ges.ges
    if kind=="tap" then
        for _,b in ipairs(self.buttons) do
            if b.rect:contains(pos) then
                if b.key then self:pulse(b.key) else UIManager:close(self,"full") end
                return true
            end
        end
    end
    if not self.rfb then return true end
    local x,y=pos.x-self.ox,pos.y-self.oy
    local inside=x>=0 and y>=0 and x<self.rfb.w and y<self.rfb.h
    local now=socket.gettime()
    local function pointer(down)
        local ok,err=pcall(self.rfb.pointer,self.rfb,x,y,down)
        if not ok then self:fail(tostring(err)) end
    end
    if kind=="touch" and inside then
        self.pointer_down=true; self.last_touch=now; pointer(true)
    elseif kind=="pan" and (inside or self.pointer_down) then
        self.pointer_down=true; self.last_touch=now; pointer(true)
    elseif kind=="release" or kind=="pan_release" then
        if self.pointer_down then pointer(false); self.pointer_down=false end
    elseif kind=="tap" and inside and now-(self.last_touch or 0)>0.6 then
        pointer(true)
        self.tap_release=function()
            if not self.closed and self.rfb then pcall(self.rfb.pointer,self.rfb,x,y,false) end
        end
        UIManager:scheduleIn(0.12,self.tap_release)
    end
    return true
end
function View:onCloseWidget()
    self.closed=true
    if self.tick then UIManager:unschedule(self.tick) end
    if self.tap_release then UIManager:unschedule(self.tap_release) end
    for cb in pairs(self.key_timers or {}) do UIManager:unschedule(cb) end
    if self.rfb then self.rfb:close(); self.rfb=nil end
    -- Stop is deliberately asynchronous: no wait/sleep in the KOReader UI thread.
    os.execute("("..command("stop")..") >>"..quote(BASE.."/android.log").." 2>&1 &")
    if self.status then self.status:free() end
    for _,b in ipairs(self.buttons or {}) do b.label:free() end
    UIManager:setDirty(nil,"full")
end
local M={}
function M.available()
    if not exists(BASE.."/android.sh") or not exists(BASE.."/bin/kobo-vnc") then return false,"Android-Paket fehlt: "..BASE end
    return true
end
function M.open()
    local ok,err=M.available()
    if not ok then UIManager:show(InfoMessage:new{text=err}); return false end
    UIManager:show(View:new{}); return true
end
M._test={RFB=RFB,quote=quote,p16=p16,p32=p32}
return M
