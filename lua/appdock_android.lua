-- SPDX-License-Identifier: MIT
-- Android KitKat through a loopback-only RFB 3.8 connection. No external viewer.
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget = require("ui/widget/textwidget")
local TextViewer = require("ui/widget/textviewer")
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
local function run_cmd(cmd, limit)
    local f = io.popen(cmd .. " 2>&1")
    if not f then return "" end
    local out = f:read("*a") or ""; f:close()
    if #out > limit then out = out:sub(-limit) end
    return out
end
local function diagnostics()
    local kmsg = tail_file(BASE .. "/run/rootfs/dev/kmsg", 2400)
    local log = tail_file(BASE .. "/android.log", 3200)
    local init = tail_file(BASE .. "/android-init.log", 1200)
    if log == "" then log = "Kein android.log vorhanden." end
    if init ~= "" then log = log .. "\n\n--- android-init.log ---\n" .. init end
    if kmsg ~= "" then log = "--- init/kmsg (live) ---\n" .. kmsg .. "\n\n--- android.log ---\n" .. log end
    -- Android-init schreibt per klog in den HOST-Kernel-Log (dmesg), nicht in die Datei dev/kmsg.
    local dm = run_cmd("dmesg | grep -iE 'init:|binder|ashmem|surfaceflinger|zygote|servicemanager|healthd|avc' | tail -n 60", 3000)
    local ps = run_cmd("ps | grep -iE '/init|zygote|surfaceflinger|servicemanager|system_server|kobo-vnc' | grep -v grep", 1500)
    -- Written by the binder shim inside libkobofb.so (KOBO_BINDER_LOG): proves LD_PRELOAD reached the
    -- Android processes and lists translation errors.
    local shim = tail_file(BASE .. "/run/rootfs/data/local/tmp/kobo-binder.log", 1500)
    local watch = tail_file(BASE .. "/bootwatch.log", 1500)
    if watch ~= "" then log = "--- Boot-Zeitachse ---\n" .. watch .. "\n\n" .. log end
    local lc = tail_file(BASE .. "/logcat.txt", 2500)
    local tb = tail_file(BASE .. "/tombstone.txt", 1500)
    if tb ~= "" then log = "--- tombstone ---\n" .. tb .. "\n\n" .. log end
    log = "--- logcat ---\n" .. (lc ~= "" and lc or "(leer: android.log ohne Eintraege)") .. "\n\n" .. log
    local hd = tail_file(BASE .. "/healthd.txt", 1500)
    if hd ~= "" then log = "--- healthd ---\n" .. hd .. "\n\n" .. log end
    local egl = tail_file(BASE .. "/egl.txt", 2000)
    if egl ~= "" then log = "--- egl ---\n" .. egl .. "\n\n" .. log end
    log = "--- binder shim ---\n" .. (shim ~= "" and shim or "(leer: Shim wurde in keinem Prozess geladen)") .. "\n\n" .. log
    log = "--- Prozesse ---\n" .. (ps ~= "" and ps or "(keine Android-Prozesse)") ..
          "\n\n--- dmesg (init/Android) ---\n" .. (dm ~= "" and dm or "(leer)") .. "\n\n" .. log
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
-- 2x2-Bayer-Matrix fuer 1-Bit-Dithering je Farbkanal. Dadurch entstehen
-- ausschliesslich die acht Farben (RGB jeweils 0 oder 255).
local BAYER2={{0,2},{3,1}}
local function dither_channel(value,x,y)
    local threshold=(BAYER2[y%2+1][x%2+1]+0.5)*64
    return value>=threshold and 255 or 0
end
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
                local dst=ffi.cast("uint8_t*",self.bb.data)+(r.y+row)*stride+r.x*4
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
-- KOReader liefert fuer das Ende einer Beruehrung je nach Geste "tap", "swipe", "hold_release",
-- "pan_release" oder "double_tap" (eine rohe Geste "release" gibt es nicht zuverlaessig). Wer nur auf
-- "release"/"pan_release" lauscht, laesst BTN_TOUCH in Android fuer immer gedrueckt: Touch wirkt tot.
local END_GESTURES={release=true,pan_release=true,tap=true,hold_release=true,swipe=true,double_tap=true}
local function pointer_action(kind,pointer_down,inside)
    if kind=="touch" then return inside and "down" or nil
    elseif kind=="pan" then return (inside or pointer_down) and "move" or nil
    elseif END_GESTURES[kind] then
        if pointer_down then return "up" end
        if kind=="tap" and inside then return "tap" end
    end
    return nil
end
local View=InputContainer:extend{name="KoboAndroid",covers_fullscreen=true}
function View:init()
    self.dimen=Geom:new{x=0,y=0,w=Screen:getWidth(),h=Screen:getHeight()}
    self.ges_events={}
    for _,g in ipairs({"touch","release","tap","pan","pan_release","hold","hold_release","swipe","double_tap"}) do
        self.ges_events[g]={GestureRange:new{ges=g,range=self.dimen},event="AndroidGesture"}
    end
    self.key_events={AndroidBack={{"Back"},event="AndroidBack"}}
    self.face=Font:getFace("cfont",22)
    self.status=TextWidget:new{text="Android startet. Der erste Boot kann mehrere Minuten dauern.",face=self.face,max_width=self.dimen.w-40}
    self.buttons={}
    local defs={{"Zurück",0xff1b},{"Home",0xff50},{"Menü",0xffbe},{"Log","log"},{"Beenden",false}}
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
    if self.rfb then
        -- Das Android-Bild nimmt die gesamte Fläche oberhalb der Buttons ein.
        -- blitFrom() skaliert nicht; deshalb wird hier mit nearest-neighbour
        -- direkt zwischen den beiden RGB32-Blitbuffer kopiert und dabei auf
        -- die acht erlaubten Farben gedithert.
        local src=self.rfb.bb
        local src_stride=tonumber(src.stride) or self.rfb.w*4
        local dst_stride=tonumber(bb.stride) or self.dimen.w*4
        local src_base=ffi.cast("const uint8_t*",src.data)
        local dst_base=ffi.cast("uint8_t*",bb.data)
        for dy=0,self.draw_h-1 do
            local sy=math.min(self.rfb.h-1,math.floor(dy*self.rfb.h/self.draw_h))
            local srow=src_base+sy*src_stride
            local drow=dst_base+(y+self.oy+dy)*dst_stride+(x+self.ox)*4
            for dx=0,self.draw_w-1 do
                local sx=math.min(self.rfb.w-1,math.floor(dx*self.rfb.w/self.draw_w))
                local sp=srow+sx*4
                local dp=drow+dx*4
                dp[0]=dither_channel(sp[0],dx,dy)
                dp[1]=dither_channel(sp[1],dx,dy)
                dp[2]=dither_channel(sp[2],dx,dy)
                dp[3]=255
            end
        end
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
            self.rfb=rfb
            self.draw_w=self.dimen.w
            self.draw_h=self.dimen.h-90
            self.ox=0; self.oy=0
            self.next_full_refresh=socket.gettime()+30
            UIManager:setDirty(self,"full")
        elseif socket.gettime()>self.deadline then self:fail("Android konnte nicht gestartet werden."); return end
    else
        local ok,changed=pcall(self.rfb.poll,self.rfb)
        if not ok then self:fail(tostring(changed)); return end
        local now=socket.gettime()
        local mode=changed and "fast" or nil
        if now >= (self.next_full_refresh or now+30) then
            mode="full"
            self.next_full_refresh=now+30
        end
        if mode=="full" then
            UIManager:setDirty(self,"full")
        elseif mode=="fast" then
            UIManager:setDirty(self,"fast",Geom:new{x=self.ox,y=self.oy,w=self.draw_w,h=self.draw_h})
        end
    end
    UIManager:scheduleIn(0.05,self.tick)
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
function View:showLog()
    UIManager:show(TextViewer:new{title="Android-Log",text=diagnostics(),width=self.dimen.w,height=self.dimen.h})
end
-- Sicherheitsnetz: geht jedes Ende-Ereignis verloren, wird die Beruehrung nach 6 s trotzdem geloest.
function View:disarmWatchdog()
    if self.watchdog then UIManager:unschedule(self.watchdog); self.watchdog=nil end
end
function View:armWatchdog()
    self:disarmWatchdog()
    self.watchdog=function()
        self.watchdog=nil
        if self.pointer_down and not self.closed and self.rfb then
            self.pointer_down=false
            pcall(self.rfb.pointer,self.rfb,self.px or 0,self.py or 0,false)
        end
    end
    UIManager:scheduleIn(6,self.watchdog)
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
                if b.key=="log" then self:showLog()
                elseif b.key then self:pulse(b.key) else UIManager:close(self,"full") end
                return true
            end
        end
    end
    if not self.rfb then return true end
    local sx,sy=pos.x-self.ox,pos.y-self.oy
    local inside=sx>=0 and sy>=0 and sx<self.draw_w and sy<self.draw_h
    -- Die sichtbare, skalierte Position wird in die native Android-Auflösung
    -- zurückgerechnet, damit Touch trotz Vollbilddarstellung korrekt bleibt.
    local x,y=sx*self.rfb.w/self.draw_w,sy*self.rfb.h/self.draw_h
    local now=socket.gettime()
    local function pointer(down,px,py)
        local ok,err=pcall(self.rfb.pointer,self.rfb,px,py,down)
        if not ok then self:fail(tostring(err)) end
    end
    local action=pointer_action(kind,self.pointer_down,inside)
    if action=="down" or action=="move" then
        self.pointer_down=true; self.px,self.py=x,y; pointer(true,x,y); self:armWatchdog()
    elseif action=="up" then
        self.pointer_down=false; self:disarmWatchdog()
        pointer(false,self.px or x,self.py or y)
    elseif action=="tap" then
        -- Beruehrung ohne vorheriges "touch" (z.B. verlorenes Ereignis): Tipp nachbilden.
        pointer(true,x,y)
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
    self:disarmWatchdog()
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
M._test={RFB=RFB,quote=quote,p16=p16,p32=p32,pointer_action=pointer_action}
return M
