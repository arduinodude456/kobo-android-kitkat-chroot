/* SPDX-License-Identifier: MIT */
#define _GNU_SOURCE
#include "kobo_fb.h"
#include "kobo_input.h"
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t stopping;
static void stop_signal(int n) { (void)n; stopping = 1; }
static int64_t milliseconds(void)
{
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}
static unsigned get16(const unsigned char *p) { return ((unsigned)p[0] << 8) | p[1]; }
static uint32_t get32(const unsigned char *p)
{ return ((uint32_t)p[0]<<24) | ((uint32_t)p[1]<<16) | ((uint32_t)p[2]<<8) | p[3]; }
static void put16(unsigned char *p, unsigned v) { p[0]=(unsigned char)(v>>8); p[1]=(unsigned char)v; }
static void put32(unsigned char *p, uint32_t v)
{ p[0]=(unsigned char)(v>>24); p[1]=(unsigned char)(v>>16); p[2]=(unsigned char)(v>>8); p[3]=(unsigned char)v; }
static int transfer(int fd, void *data, size_t len, int writing, int64_t deadline)
{
    unsigned char *p = data;
    while (len && !stopping) {
        struct pollfd pollfd; int64_t left = deadline - milliseconds(); int rc; ssize_t n;
        if (left <= 0) { errno = ETIMEDOUT; return -1; }
        pollfd.fd = fd; pollfd.events = writing ? POLLOUT : POLLIN; pollfd.revents = 0;
        rc = poll(&pollfd, 1, (int)left);
        if (rc < 0 && errno == EINTR) continue;
        if (rc <= 0) { if (!rc) errno = ETIMEDOUT; return -1; }
        if (!(pollfd.revents & pollfd.events)) { errno = ECONNRESET; return -1; }
        n = writing ? send(fd, p, len, MSG_NOSIGNAL | MSG_DONTWAIT) : recv(fd, p, len, MSG_DONTWAIT);
        if (n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
        if (n <= 0) { if (!n) errno = ECONNRESET; return -1; }
        p += n; len -= (size_t)n;
    }
    return len ? -1 : 0;
}
static int read_until(int fd, void *p, size_t n, int64_t deadline)
{ return transfer(fd, p, n, 0, deadline); }
static int write_until(int fd, const void *p, size_t n, int64_t deadline)
{ return transfer(fd, (void *)p, n, 1, deadline); }
struct format { unsigned bytes, depth, big, rm, gm, bm, rs, gs, bs; };
static void default_format(struct format *f)
{ f->bytes=2; f->depth=16; f->big=0; f->rm=31; f->gm=63; f->bm=31; f->rs=11; f->gs=5; f->bs=0; }
static int parse_format(const unsigned char *p, struct format *f)
{
    uint32_t rmask, gmask, bmask; unsigned rbits, gbits, bbits;
    if ((p[0] != 16 && p[0] != 24 && p[0] != 32) || p[2] > 1 || p[3] != 1) return -1;
    f->bytes=p[0]/8; f->depth=p[1]; f->big=p[2];
    f->rm=get16(p+4); f->gm=get16(p+6); f->bm=get16(p+8);
    f->rs=p[10]; f->gs=p[11]; f->bs=p[12];
    if (f->bytes==2) {
        if (f->depth!=16 || f->rm!=31 || f->gm!=63 || f->bm!=31) return -1;
        rbits=5; gbits=6; bbits=5;
    } else {
        if (f->depth!=24 || f->rm!=255 || f->gm!=255 || f->bm!=255) return -1;
        rbits=gbits=bbits=8;
    }
    if (f->rs+rbits>p[0] || f->gs+gbits>p[0] || f->bs+bbits>p[0]) return -1;
    rmask=(uint32_t)f->rm<<f->rs; gmask=(uint32_t)f->gm<<f->gs; bmask=(uint32_t)f->bm<<f->bs;
    return ((rmask & gmask) || (rmask & bmask) || (gmask & bmask)) ? -1 : 0;
}
static int handshake(int fd, unsigned w, unsigned h)
{
    unsigned char buf[64]; int64_t deadline=milliseconds()+5000;
    static const char version[]="RFB 003.008\n", name[]="Kobo Android framebuffer";
    if (write_until(fd, version, 12, deadline) || read_until(fd, buf, 12, deadline) || memcmp(buf,version,12)) return -1;
    buf[0]=1; buf[1]=1;
    if (write_until(fd,buf,2,deadline) || read_until(fd,buf,1,deadline) || buf[0]!=1) return -1;
    memset(buf,0,4);
    if (write_until(fd,buf,4,deadline) || read_until(fd,buf,1,deadline) || buf[0]>1) return -1;
    memset(buf,0,24); put16(buf,w); put16(buf+2,h);
    buf[4]=16; buf[5]=16; buf[7]=1; put16(buf+8,31); put16(buf+10,63); put16(buf+12,31);
    buf[14]=11; buf[15]=5; put32(buf+20,sizeof(name)-1);
    return write_until(fd,buf,24,deadline) || write_until(fd,name,sizeof(name)-1,deadline) ? -1 : 0;
}
struct request { unsigned x,y,w,h; int incremental,pending; };
static int message(int fd, struct format *fmt, struct request *q,
                   struct kobo_input *input, unsigned width, unsigned height, int *valid)
{
    unsigned char b[512], type; unsigned n,j; int64_t deadline=milliseconds()+5000;
    if (read_until(fd,&type,1,deadline)) return -1;
    switch(type) {
    case 0:
        if (read_until(fd,b,19,deadline) || parse_format(b+3,fmt)) return -1;
        *valid=0; return 0;
    case 2: {
        int raw=0;
        if (read_until(fd,b,3,deadline)) return -1;
        n=get16(b+1); if (n>128) return -1;
        for(j=0;j<n;++j) { if(read_until(fd,b,4,deadline))return -1; if(!get32(b))raw=1; }
        /* Raw encoding is universally supported by RFB, including an empty list. */
        (void)raw; return 0;
    }
    case 3:
        if (read_until(fd,b,9,deadline) || b[0]>1) return -1;
        q->incremental=b[0]; q->x=get16(b+1); q->y=get16(b+3); q->w=get16(b+5); q->h=get16(b+7);
        if(q->x>width || q->y>height || q->w>width-q->x || q->h>height-q->y) return -1;
        q->pending=1; return 0;
    case 4:
        if(read_until(fd,b,7,deadline) || b[0]>1)return -1;
        return kobo_input_key(input,get32(b+3),b[0]);
    case 5:
        if(read_until(fd,b,5,deadline))return -1;
        return kobo_input_pointer(input,b[0],get16(b+1),get16(b+3));
    case 6:
        if(read_until(fd,b,7,deadline))return -1;
        n=get32(b+3); if(n>65536)return -1;
        while(n) { unsigned chunk=n>sizeof(b)?sizeof(b):n;
            if(read_until(fd,b,chunk,deadline))return -1;
            n-=chunk;
        }
        return 0;
    default: return -1;
    }
}
static void convert_row(unsigned char *out, const unsigned char *src, unsigned count, const struct format *f)
{
    unsigned x;
    for(x=0;x<count;++x) {
        uint32_t value=(uint32_t)src[0] | ((uint32_t)src[1]<<8), r=(value>>11)&31, g=(value>>5)&63, b=value&31;
        unsigned j;
        if(f->bytes!=2) { r=(r<<3)|(r>>2); g=(g<<2)|(g>>4); b=(b<<3)|(b>>2); }
        value=(r<<f->rs)|(g<<f->gs)|(b<<f->bs);
        for(j=0;j<f->bytes;++j) out[j]=(unsigned char)(value>>(8*(f->big?f->bytes-1-j:j)));
        src+=2; out+=f->bytes;
    }
}
static int update(int fd, struct kobo_fb *fb, const struct format *fmt, struct request *q,
                  unsigned char *last, int *valid, unsigned char *row)
{
    struct kobo_fb_meta m; unsigned y,first=q->y+q->h,end=q->y, stride=fb->meta->width*2;
    unsigned char header[16]; const unsigned char *page; int64_t deadline;
    if(!q->pending)return 0;
    if(kobo_fb_snapshot(fb->meta,&m))return 0;
    if(m.magic!=KOBO_FB_MAGIC || m.abi_version!=KOBO_FB_ABI || m.width!=fb->meta->width ||
       m.height!=fb->meta->height || m.stride!=stride || m.yoffset>m.height) { errno=EINVAL; return -1; }
    page=fb->pixels+(size_t)m.yoffset*stride;
    if(!q->incremental || !*valid) { first=q->y; end=q->y+q->h; }
    else for(y=q->y;y<q->y+q->h;++y) {
        size_t off=(size_t)y*stride+(size_t)q->x*2;
        if(memcmp(page+off,last+off,(size_t)q->w*2)) { if(first>y)first=y; end=y+1; }
    }
    if(q->w && q->h && first>=end)return 0; /* Defer; continue polling input. */
    deadline=milliseconds()+5000; memset(header,0,sizeof(header));
    if(!q->w || !q->h) { q->pending=0; return write_until(fd,header,4,deadline); }
    put16(header+2,1); put16(header+4,q->x); put16(header+6,first);
    put16(header+8,q->w); put16(header+10,end-first); /* encoding 0: raw */
    if(write_until(fd,header,sizeof(header),deadline))return -1;
    for(y=first;y<end;++y) {
        size_t off=(size_t)y*stride+(size_t)q->x*2;
        /* Take one small row snapshot; remember precisely what was transmitted. */
        memcpy(last+off,page+off,(size_t)q->w*2);
        convert_row(row,last+off,q->w,fmt);
        if(write_until(fd,row,(size_t)q->w*fmt->bytes,deadline))return -1;
    }
    if(q->x==0 && first==0 && q->w==m.width && end==m.height)*valid=1;
    q->pending=0; return 0;
}
static void release_keys(struct kobo_input *i)
{
    unsigned code;
    if(i->touching) kobo_input_pointer(i,0,0,0);
    /* Disconnect must never leave a virtual key held in Android. */
    if(i->keyboard>=0) for(code=1;code<sizeof(i->keys);++code) if(i->keys[code]) {
        struct input_event e; memset(&e,0,sizeof(e)); e.type=EV_KEY; e.code=(unsigned short)code;
        ssize_t sent = write(i->keyboard,&e,sizeof(e));
        if (sent != (ssize_t)sizeof(e)) break;
        e.type=EV_SYN; e.code=SYN_REPORT;
        sent = write(i->keyboard,&e,sizeof(e));
        if (sent != (ssize_t)sizeof(e)) break;
        i->keys[code]=0;
    }
}
static int serve_client(int fd,struct kobo_fb *fb,struct kobo_input *input)
{
    struct format fmt; struct request q; unsigned char *last,*row; int valid=0,rc=-1;
    default_format(&fmt); memset(&q,0,sizeof(q));
    if(handshake(fd,fb->meta->width,fb->meta->height))return -1;
    last=calloc(1,fb->bytes/2); row=malloc((size_t)fb->meta->width*4);
    if(!last || !row) { free(last); free(row); return -1; }
    while(!stopping) {
        struct pollfd p; int n; p.fd=fd; p.events=POLLIN; p.revents=0;
        n=poll(&p,1,50);
        if(n<0) { if(errno==EINTR)continue; break; }
        if(n>0) {
            if(!(p.revents&POLLIN))break;
            if(message(fd,&fmt,&q,input,fb->meta->width,fb->meta->height,&valid))break;
        }
        if(update(fd,fb,&fmt,&q,last,&valid,row))break;
    }
    free(last); free(row); release_keys(input); return rc;
}
static void usage(FILE *f)
{
    fprintf(f,"Usage: kobo-vnc --shared DIR --input-dir DIR [--port 5963] [--width N --height N]\n"
        "       kobo-vnc --check\n"
        "       kobo-vnc --shared DIR --no-input [--port N] [--width N --height N]\n"
        "RFB 3.8 raw RGB565/RGB888, one client, IPv4 127.0.0.1 ONLY. No authentication;\n"
        "use an SSH tunnel and trust local processes. --no-input is explicit off-device\n"
        "testing only, never an automatic fallback. Dimensions default to 600x800 or\n"
        "KOBO_FB_WIDTH/KOBO_FB_HEIGHT (1..4096). Existing shared dimensions must match.\n"
        "--check probes Binder protocol 7/8, ashmem size, uinput creation and namespaces.\n"
        "Probe paths: KOBO_BINDER_DEVICE and KOBO_ASHMEM_DEVICE.\n");
}
static int number(const char *s,unsigned max,unsigned *out)
{
    char *end; unsigned long v; errno=0; v=strtoul(s,&end,10);
    if(errno || !*s || *end || !v || v>max)return -1;
    *out=(unsigned)v; return 0;
}
int main(int argc,char **argv)
{
    const char *dir=NULL,*input_dir=NULL; uint32_t w,h; unsigned port=5963; int no_input=0,check=0;
    int i,listener=-1,result=1; struct kobo_fb fb; struct kobo_input input; struct sockaddr_in address;
    memset(&fb,0,sizeof(fb)); fb.pixels_fd=fb.meta_fd=-1;
    memset(&input,0,sizeof(input)); input.touch=input.keyboard=-1;
    if(kobo_fb_dimensions(&w,&h)) { fprintf(stderr,"invalid KOBO_FB_WIDTH/HEIGHT\n"); return 2; }
    for(i=1;i<argc;++i) {
        if(!strcmp(argv[i],"--help")) { usage(stdout); return 0; }
        else if(!strcmp(argv[i],"--check"))check=1;
        else if(!strcmp(argv[i],"--no-input"))no_input=1;
        else if(i+1<argc && !strcmp(argv[i],"--shared"))dir=argv[++i];
        else if(i+1<argc && !strcmp(argv[i],"--input-dir"))input_dir=argv[++i];
        else if(i+1<argc && !strcmp(argv[i],"--port")) { if(number(argv[++i],65535,&port))goto bad; }
        else if(i+1<argc && !strcmp(argv[i],"--width")) { if(number(argv[++i],KOBO_FB_MAX_DIM,&w))goto bad; }
        else if(i+1<argc && !strcmp(argv[i],"--height")) { if(number(argv[++i],KOBO_FB_MAX_DIM,&h))goto bad; }
        else goto bad;
    }
    if(check) { if(no_input)goto bad; return kobo_probe(); }
    if(!dir || (!no_input && !input_dir) || (no_input && input_dir))goto bad;
    signal(SIGINT,stop_signal); signal(SIGTERM,stop_signal); signal(SIGPIPE,SIG_IGN);
    if(mkdir(dir,0755)<0 && errno!=EEXIST) { perror("shared directory"); goto done; }
    if(kobo_fb_create(dir,w,h,&fb)) { perror("framebuffer initialization"); goto done; }
    /* Launcher runs as root; SF (system:graphics) must be able to open both files. */
    if(geteuid()==0 && (fchown(fb.pixels_fd,1000,1003)<0 || fchown(fb.meta_fd,1000,1003)<0)) {
        perror("framebuffer ownership"); goto done;
    }
    if(fchmod(fb.pixels_fd,0660)<0 || fchmod(fb.meta_fd,0660)<0) { perror("framebuffer permissions"); goto done; }
    if(!no_input && kobo_input_create(&input,input_dir,w,h)) { perror("private uinput creation/discovery"); goto done; }
    listener=socket(AF_INET,SOCK_STREAM,0);
    if(listener<0) { perror("socket"); goto done; }
    { int one=1; setsockopt(listener,SOL_SOCKET,SO_REUSEADDR,&one,sizeof(one)); }
    fcntl(listener,F_SETFD,FD_CLOEXEC);
    memset(&address,0,sizeof(address)); address.sin_family=AF_INET; address.sin_port=htons((uint16_t)port);
    address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
    if(bind(listener,(struct sockaddr *)&address,sizeof(address))<0 || listen(listener,1)<0) { perror("loopback listener"); goto done; }
    fprintf(stderr,"kobo-vnc: 127.0.0.1:%u, %ux%u RGB565 double buffer%s\n",port,w,h,no_input?" (input disabled explicitly)":"");
    result=0;
    while(!stopping) {
        struct pollfd p; int n,client,one=1; struct sockaddr_in peer; socklen_t plen=sizeof(peer);
        p.fd=listener; p.events=POLLIN; p.revents=0; n=poll(&p,1,500);
        if(n<0 && errno==EINTR)continue;
        if(n<0) { perror("listener poll"); result=1; break; }
        if(!n)continue;
        if(!(p.revents&POLLIN)) { result=1; break; }
        client=accept(listener,(struct sockaddr *)&peer,&plen);
        if(client<0) { if(errno==EINTR)continue; perror("accept"); continue; }
        if(peer.sin_addr.s_addr!=htonl(INADDR_LOOPBACK)) { close(client); continue; }
        fcntl(client,F_SETFD,FD_CLOEXEC); setsockopt(client,IPPROTO_TCP,TCP_NODELAY,&one,sizeof(one));
        { struct timeval timeout; timeout.tv_sec=5; timeout.tv_usec=0;
          setsockopt(client,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
          setsockopt(client,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout)); }
        (void)serve_client(client,&fb,&input); close(client);
    }
done:
    if(listener>=0)close(listener);
    kobo_input_destroy(&input); kobo_fb_release(&fb); return result;
bad:
    usage(stderr); return 2;
}
