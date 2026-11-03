-- SPDX-License-Identifier: MIT
local ffi=require("ffi")
local function stub(name,value) package.preload[name]=function() return value or {} end end
stub("ffi/blitbuffer",{})
stub("device",{screen={}})
for _,name in ipairs({"ui/font","ui/geometry","ui/gesturerange","ui/widget/infomessage","ui/widget/textwidget","ui/widget/textviewer","ui/uimanager"}) do stub(name,{}) end
stub("ui/widget/container/inputcontainer",{extend=function(_,v)return v end})
stub("socket",{gettime=os.clock})
local module=dofile("lua/appdock_android.lua")
local RFB=module._test.RFB
local p16,p32=module._test.p16,module._test.p32
local count=0
local function check(v,message) count=count+1; assert(v,message) end
local function client(chunks)
    local pixels=ffi.new("uint8_t[16]")
    local sock={sent={},chunks=chunks or {}}
    function sock:settimeout()end
    function sock:send(data)self.sent[#self.sent+1]=data;return #data end
    function sock:receive()local c=table.remove(self.chunks,1);return nil,"timeout",c or "" end
    local r=setmetatable({sock=sock,w=2,h=2,buf="",bb={data=pixels,stride=8}},RFB)
    return r,pixels,sock
end
local red=string.char(255,0,0,0)
local update="\0\0"..p16(1)..p16(0)..p16(0)..p16(2)..p16(2)..p32(0)..red:rep(4)
local r,pixels,sock=client({update:sub(1,7),update:sub(8,19),update:sub(20)})
check(not r:poll(),"partial header must not draw")
check(not r:poll(),"partial pixels must not draw")
check(r:poll(),"full fragmented pixels must draw")
check(pixels[0]==255 and pixels[1]==0 and pixels[3]==255,"RGB32 and opaque alpha")
check(#sock.sent==1 and sock.sent[1]:byte(1)==3,"request next incremental frame")
local empty,_,es=client({"\0\0\0\0"})
check(not empty:poll(),"empty update is not a repaint")
check(#es.sent==1,"empty update cannot stall the stream")
local bad=client({"\0\0"..p16(1)..p16(1)..p16(0)..p16(2)..p16(2)..p32(0)})
check(not pcall(bad.poll,bad),"out-of-bounds rectangle rejected")
local encoding=client({"\0\0"..p16(1)..p16(0)..p16(0)..p16(2)..p16(2)..p32(5)})
check(not pcall(encoding.poll,encoding),"non-raw encoding rejected")
local clip=client({"\3\0\0\0"..p32(999999)})
check(not pcall(clip.poll,clip),"oversized clipboard rejected")
local ptr,_,ps=client()
ptr:pointer(-10,99,true)
check(ps.sent[1]=="\5\1\0\0\0\1","pointer clamped")
check(module._test.quote("a'b")=="'a'\\''b'","shell argument escaped")
print("Lua RFB: "..count.." assertions passed")
