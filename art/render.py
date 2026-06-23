import zlib, struct, math

W = H = 400
SS = 3

BG=(32,40,58); BORDER=(51,64,90)
GOLD=(236,187,63); GOLD_D=(185,133,29); GOLD_BAR=(207,156,44); GREEN=(38,184,132)
COINEDGE=(185,133,29); LETTER=(122,86,16)
SCALLOP=[88,144,200,256,312]

def rr(x,y,x0,y0,w,h,r):
    x1=x0+w; y1=y0+h
    if x<x0 or x>x1 or y<y0 or y>y1: return False
    cx=x0+r if x<x0+r else (x1-r if x>x1-r else x)
    cy=y0+r if y<y0+r else (y1-r if y>y1-r else y)
    dx=x-cx; dy=y-cy
    return dx*dx+dy*dy<=r*r

def circ(x,y,cx,cy,rad):
    dx=x-cx; dy=y-cy; return dx*dx+dy*dy<=rad*rad

def in_G(x,y):
    cx,cy=200.0,300.0
    dx=x-cx; dy=y-cy
    d=math.hypot(dx,dy)
    if 22<=d<=40:
        ang=math.degrees(math.atan2(dy,dx))
        if not (-42<ang<30 and x>cx):
            return True
    if cx-2<=x<=cx+40 and cy-2<=y<=cy+12:
        return True
    return False

def sample(x,y):
    if not rr(x,y,0,0,400,400,92): return (0,0,0,0)
    col=BG
    if rr(x,y,8,8,384,384,84) and not rr(x,y,12,12,376,376,80):
        col=BORDER
    inA = (60<=x<=340 and 98<=y<=170)
    if not inA and 170<=y<=198:
        for scx in SCALLOP:
            if (x-scx)**2+(y-170)**2<=784:
                inA=True; break
    if inA:
        k=int((x-60)//56); k=0 if k<0 else (4 if k>4 else k)
        col=GOLD if k%2==0 else GREEN
    if rr(x,y,50,86,300,16,6):
        col=GOLD_BAR
    if circ(x,y,200,300,74):
        col = GOLD if circ(x,y,200,300,67) else COINEDGE
        if in_G(x,y): col=LETTER
    return (col[0],col[1],col[2],255)

out=bytearray(W*H*4)
n=SS*SS
for oy in range(H):
    for ox in range(W):
        r=g=b=a=0.0
        for sy in range(SS):
            for sx in range(SS):
                cr,cg,cb,ca=sample(ox+(sx+0.5)/SS, oy+(sy+0.5)/SS)
                r+=cr*ca; g+=cg*ca; b+=cb*ca; a+=ca
        if a>0: R=int(r/a+0.5); G=int(g/a+0.5); B=int(b/a+0.5)
        else: R=G=B=0
        A=int(a/n+0.5)
        i=(oy*W+ox)*4; out[i]=R; out[i+1]=G; out[i+2]=B; out[i+3]=A

def png(path,w,h,data):
    def chunk(t,d): return struct.pack(">I",len(d))+t+d+struct.pack(">I",zlib.crc32(t+d)&0xffffffff)
    raw=bytearray(); s=w*4
    for y in range(h): raw.append(0); raw.extend(data[y*s:(y+1)*s])
    with open(path,"wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR",struct.pack(">IIBBBBB",w,h,8,6,0,0,0)))
        f.write(chunk(b"IDAT",zlib.compress(bytes(raw),9)))
        f.write(chunk(b"IEND",b""))

png("art/icon.png",W,H,out)
print("wrote art/icon.png")
