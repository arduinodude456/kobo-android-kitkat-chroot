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
    local sock={sent={},chunks=chunks or {}}
    function sock:settimeout()end
    function sock:send(data)self.sent[#self.sent+1]=data;return #data end
    function sock:receive()local c=table.remove(self.chunks,1);return nil,"timeout",c or "" end
    local r=RFB.attach(sock,2,2)
    return r,r.fb,sock
end
local red=string.char(0x00,0xF8) -- RGB565 little endian: 0xF800
local update="\0\0"..p16(1)..p16(0)..p16(0)..p16(2)..p16(2)..p32(0)..red:rep(4)
local r,fb,sock=client({update:sub(1,7),update:sub(8,19),update:sub(20)})
check(not r:poll(),"partial header must not draw")
check(not r:poll(),"partial pixels must not draw")
check(r:poll(),"full fragmented pixels must draw")
check(fb[0]==0xF800 and fb[3]==0xF800,"RGB565 pixels copied into the local framebuffer")
local dx0,dy0,dx1,dy1=r:take_dirty()
check(dx0==0 and dy0==0 and dx1==2 and dy1==2,"dirty rectangle covers the update")
check(r:take_dirty()==nil,"dirty rectangle is consumed")
check(#sock.sent==1 and sock.sent[1]:byte(1)==3,"request next incremental frame")
-- Teil-Rechteck (x=1,y=1,1x1) darf nur sein eigenes Pixel veraendern.
local green=string.char(0xE0,0x07)
local part,pfb=client({"\0\0"..p16(1)..p16(1)..p16(1)..p16(1)..p16(1)..p32(0)..green})
check(part:poll(),"partial rectangle must draw")
check(pfb[3]==0x07E0 and pfb[0]==0xFFFF and pfb[1]==0xFFFF and pfb[2]==0xFFFF,"only the target pixel changes")
local d0,e0,d1,e1=part:take_dirty()
check(d0==1 and e0==1 and d1==2 and e1==2,"dirty rectangle of a partial update")
-- Zwei Updates in einem Socket-Lesevorgang werden beide verarbeitet.
local two,tfb=client({update..("\0\0"..p16(1)..p16(0)..p16(0)..p16(1)..p16(1)..p32(0)..green)})
check(two:poll(),"back-to-back updates in one read")
check(tfb[0]==0x07E0 and tfb[1]==0xF800,"second update applied after the first")
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
-- Touch-Ende: jede Geste, die eine Beruehrung beendet, muss den Zeiger loslassen (sonst BTN_TOUCH haengt).
local pa=module._test.pointer_action
check(pa("touch",false,true)=="down" and pa("touch",false,false)==nil,"touch presses only inside Android view")
check(pa("pan",true,false)=="move" and pa("pan",false,false)==nil,"pan continues an active press")
for _,k in ipairs({"release","pan_release","tap","hold_release","swipe","double_tap"}) do
    check(pa(k,true,true)=="up","gesture "..k.." releases an active press")
end
check(pa("tap",false,true)=="tap" and pa("tap",false,false)==nil,"tap without prior touch is synthesized only inside")
check(pa("hold",true,true)==nil,"hold keeps the press")
-- Dither-Tabelle gegen eine unabhaengige Referenz (Farbaufbereitung + 4x4-Bayer) pruefen.
local bit=require("bit")
local D=module._test.COLOR_DEFAULTS
local lut=module._test.build_lut(D)
local BY=module._test.BAYER4
local function ref_pixel(p,dx,dy)
    local r4,g4,b4=bit.rshift(p,12),bit.band(bit.rshift(p,7),15),bit.band(bit.rshift(p,1),15)
    local c={(r4/15)^D.gamma,(g4/15)^D.gamma,(b4/15)^D.gamma}
    local l=0.299*c[1]+0.587*c[2]+0.114*c[3]
    local t=(BY[(dy%4)*4+(dx%4)+1]+0.5)/16
    local v=0xff000000
    for i=1,3 do
        local x=l+(c[i]-l)*D.sat
        x=(x-0.5)*D.contrast+0.5
        x=math.max(0,math.min(1,x))
        if x>=t then v=v+(i==1 and 0xff or i==2 and 0xff00 or 0xff0000) end
    end
    return v
end
local function lut_pixel(p,dx,dy)
    local idx=bit.band(bit.rshift(p,4),0xF00)+bit.band(bit.rshift(p,3),0xF0)+bit.band(bit.rshift(p,1),0xF)
    return lut[(dy%4)*16384+(dx%4)*4096+idx]
end
for _,p in ipairs({0,0xFFFF,0xF800,0x07E0,0x001F,0x8410,0x4208,0xC618,0x1234,0xABCD}) do
    for dy=0,3 do for dx=0,3 do
        check(lut_pixel(p,dx,dy)==ref_pixel(p,dx,dy),"dither LUT matches reference for "..p.." phase "..dx..","..dy)
    end end
end
-- Neutrale Farben duerfen keinen Farbstich bekommen (Text/UI bleibt schwarz-weiss).
for _,p in ipairs({0x0000,0x8410,0xFFFF,0x4208,0xC618}) do
    for dy=0,3 do for dx=0,3 do
        local v=lut_pixel(p,dx,dy)
        local r,g,b=bit.band(v,0xff),bit.band(bit.rshift(v,8),0xff),bit.band(bit.rshift(v,16),0xff)
        check(r==g and g==b,"gray stays neutral: "..p)
    end end
end
check(lut_pixel(0xFFFF,0,0)==0xffffffff and lut_pixel(0,3,3)==0xff000000,"white and black are preserved")
-- Teil-Rendering == Voll-Rendering (Skalierung 5x6 -> 13x17, nicht ganzzahlig).
local W,H,DW,DH=5,6,13,17
local src=ffi.new("uint16_t[?]",W*H)
for i=0,W*H-1 do src[i]=(i*2741+97)%65536 end
local xm,ym=ffi.new("uint16_t[?]",DW),ffi.new("uint16_t[?]",DH)
for dx=0,DW-1 do xm[dx]=math.min(W-1,math.floor(dx*W/DW)) end
for dy=0,DH-1 do ym[dy]=math.min(H-1,math.floor(dy*H/DH)) end
local full=ffi.new("uint32_t[?]",DW*DH)
module._test.render_region(src,W,H,full,DW,xm,ym,DW,DH,0,0,W,H,lut)
local inc=ffi.new("uint32_t[?]",DW*DH)
for _,rc in ipairs({{0,0,W,3},{0,3,W,H}}) do
    module._test.render_region(src,W,H,inc,DW,xm,ym,DW,DH,rc[1],rc[2],rc[3],rc[4],lut)
end
local same=true
for i=0,DW*DH-1 do if full[i]~=inc[i] then same=false end end
check(same,"region-wise rendering equals full rendering")
-- Referenz: unabhaengiger Pixel-fuer-Pixel-Weg.
for dy=0,DH-1 do for dx=0,DW-1 do
    local p=src[ym[dy]*W+xm[dx]]
    assert(full[dy*DW+dx]==ref_pixel(p,dx,dy),"pixel "..dx..","..dy)
end end
count=count+1
print("Lua RFB: "..count.." assertions passed")
