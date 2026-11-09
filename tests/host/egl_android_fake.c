/* SPDX-License-Identifier: MIT
 *
 * Host test for mesa/platform_android_kobo.c.
 *
 * Runs the *real* Mesa EGL + softpipe stack on the build host against a fake
 * Android 4.4 ANativeWindow and a fake gralloc module (headers: AOSP
 * android-4.4.4_r2).  It checks that eglSwapBuffers delivers correctly
 * converted pixels through dequeueBuffer / gralloc lock / queueBuffer.
 * It does not run bionic, SurfaceFlinger or the framework libEGL loader.
 *
 * Build/run: tests/host/run-egl-fake.sh
 */
#include <EGL/egl.h>
#include <GLES2/gl2.h>
#include <hardware/gralloc.h>
#include <hardware/hardware.h>
#include <system/window.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void kobo_fake_set_gralloc(const struct hw_module_t *m);

#define MAXBUF 3
static int failures;
#define CHECK(cond, ...) do { if (!(cond)) { failures++; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

/* ---- fake gralloc ---------------------------------------------------- */
static int g_lock_calls, g_unlock_calls, g_locked;
static int fake_lock(const struct gralloc_module_t *m, buffer_handle_t h, int usage,
                     int l, int t, int w, int hh, void **vaddr)
{
    (void) m; (void) usage; (void) l; (void) t; (void) w; (void) hh;
    g_lock_calls++; g_locked++;
    *vaddr = (void *) h;   /* the "handle" is just the pixel memory here */
    return 0;
}
static int fake_unlock(const struct gralloc_module_t *m, buffer_handle_t h)
{
    (void) m; (void) h; g_unlock_calls++; g_locked--; return 0;
}
static struct gralloc_module_t g_gralloc = {
    .common = { .tag = HARDWARE_MODULE_TAG, .module_api_version = 0, .id = GRALLOC_HARDWARE_MODULE_ID, .name = "fake" },
    .lock = fake_lock, .unlock = fake_unlock,
};

/* ---- fake ANativeWindow ---------------------------------------------- */
struct fake_window {
    struct ANativeWindow base;
    int width, height, format;
    struct ANativeWindowBuffer buf[MAXBUF];
    int busy[MAXBUF];
    int dequeued, queued, cancelled, last_queued;
    int usage;
    int refs;
};
static void fake_base_inc(struct android_native_base_t *b) { (void) b; }
static void fake_base_dec(struct android_native_base_t *b) { (void) b; }
static void win_inc(struct android_native_base_t *b) { ((struct fake_window *) b)->refs++; }
static void win_dec(struct android_native_base_t *b) { ((struct fake_window *) b)->refs--; }

static int w_query(const struct ANativeWindow *nw, int what, int *value)
{
    const struct fake_window *w = (const struct fake_window *) nw;
    switch (what) {
    case NATIVE_WINDOW_WIDTH: case NATIVE_WINDOW_DEFAULT_WIDTH: *value = w->width; return 0;
    case NATIVE_WINDOW_HEIGHT: case NATIVE_WINDOW_DEFAULT_HEIGHT: *value = w->height; return 0;
    case NATIVE_WINDOW_FORMAT: *value = w->format; return 0;
    default: return -1;
    }
}
static int w_perform(struct ANativeWindow *nw, int op, ...)
{
    struct fake_window *w = (struct fake_window *) nw;
    if (op == NATIVE_WINDOW_SET_USAGE) {
        va_list ap; va_start(ap, op); w->usage = va_arg(ap, int); va_end(ap);
    }
    return 0;
}
static int w_swap_interval(struct ANativeWindow *nw, int i) { (void) nw; (void) i; return 0; }
static int w_dequeue(struct ANativeWindow *nw, struct ANativeWindowBuffer **out, int *fence)
{
    struct fake_window *w = (struct fake_window *) nw;
    for (int i = 0; i < MAXBUF; i++) {
        if (!w->busy[i]) { w->busy[i] = 1; *out = &w->buf[i]; *fence = -1; w->dequeued++; return 0; }
    }
    return -1;
}
static int w_queue(struct ANativeWindow *nw, struct ANativeWindowBuffer *b, int fence)
{
    struct fake_window *w = (struct fake_window *) nw;
    (void) fence;
    w->busy[b - w->buf] = 0; w->queued++; w->last_queued = (int) (b - w->buf);
    return 0;
}
static int w_cancel(struct ANativeWindow *nw, struct ANativeWindowBuffer *b, int fence)
{
    struct fake_window *w = (struct fake_window *) nw;
    (void) fence;
    w->busy[b - w->buf] = 0; w->cancelled++;
    return 0;
}

static struct fake_window *make_window(int width, int height, int format, int bpp)
{
    struct fake_window *w = calloc(1, sizeof *w);
    w->width = width; w->height = height; w->format = format;
    w->base.common.magic = ANDROID_NATIVE_WINDOW_MAGIC;
    w->base.common.version = sizeof(struct ANativeWindow);
    w->base.common.incRef = win_inc; w->base.common.decRef = win_dec;
    w->base.setSwapInterval = w_swap_interval;
    w->base.query = w_query; w->base.perform = w_perform;
    w->base.dequeueBuffer = w_dequeue; w->base.queueBuffer = w_queue; w->base.cancelBuffer = w_cancel;
    for (int i = 0; i < MAXBUF; i++) {
        int stride = width + 8;                       /* padded stride, like real gralloc */
        void *mem = calloc((size_t) stride * height, bpp);
        w->buf[i].common.magic = ANDROID_NATIVE_BUFFER_MAGIC;
        w->buf[i].common.version = sizeof(struct ANativeWindowBuffer);
        w->buf[i].common.incRef = fake_base_inc; w->buf[i].common.decRef = fake_base_dec;
        w->buf[i].width = width; w->buf[i].height = height; w->buf[i].stride = stride;
        w->buf[i].format = format; w->buf[i].handle = (buffer_handle_t) mem;
    }
    return w;
}

/* ---- GL helpers ------------------------------------------------------ */
static GLuint shader(GLenum type, const char *src)
{
    GLuint s = glCreateShader(type);
    glShaderSource(s, 1, &src, NULL);
    glCompileShader(s);
    GLint ok = 0; glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) { char log[512]; glGetShaderInfoLog(s, sizeof log, NULL, log); printf("shader: %s\n", log); }
    CHECK(ok, "shader compile");
    return s;
}

static void draw_frame(int new_context)
{
    static GLuint prog;
    if (new_context) prog = 0;
    if (!prog) {
        prog = glCreateProgram();
        glAttachShader(prog, shader(GL_VERTEX_SHADER,
            "attribute vec2 p; void main(){ gl_Position = vec4(p, 0.0, 1.0); }"));
        glAttachShader(prog, shader(GL_FRAGMENT_SHADER,
            "precision mediump float; void main(){ gl_FragColor = vec4(0.0, 1.0, 0.0, 1.0); }"));
        glBindAttribLocation(prog, 0, "p");
        glLinkProgram(prog);
        GLint ok = 0; glGetProgramiv(prog, GL_LINK_STATUS, &ok);
        CHECK(ok, "program link");
    }
    static const GLfloat tri[] = { -0.5f, -0.5f,  0.5f, -0.5f,  -0.5f, 0.5f,  0.5f, 0.5f };
    glClearColor(0.f, 0.f, 1.f, 1.f);                  /* blue background */
    glClear(GL_COLOR_BUFFER_BIT);
    glUseProgram(prog);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, tri);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);              /* green square in the middle */
}

static EGLConfig choose(EGLDisplay dpy, EGLint format, EGLint surface_type)
{
    EGLint n = 0;
    EGLConfig cfgs[64];
    eglGetConfigs(dpy, cfgs, 64, &n);
    for (int i = 0; i < n; i++) {
        EGLint vid = 0, st = 0, rt = 0, depth = 0;
        eglGetConfigAttrib(dpy, cfgs[i], EGL_NATIVE_VISUAL_ID, &vid);
        eglGetConfigAttrib(dpy, cfgs[i], EGL_SURFACE_TYPE, &st);
        eglGetConfigAttrib(dpy, cfgs[i], EGL_RENDERABLE_TYPE, &rt);
        eglGetConfigAttrib(dpy, cfgs[i], EGL_DEPTH_SIZE, &depth);
        if (vid == format && (st & surface_type) && (rt & EGL_OPENGL_ES2_BIT)) return cfgs[i];
    }
    return NULL;
}

static void test_window(EGLDisplay dpy, int format, int bpp, const char *name)
{
    printf("-- window %s\n", name);
    EGLConfig cfg = choose(dpy, format, EGL_WINDOW_BIT);
    CHECK(cfg != NULL, "no ES2 window config for %s", name);
    if (!cfg) return;

    struct fake_window *w = make_window(64, 48, format, bpp);
    EGLSurface surf = eglCreateWindowSurface(dpy, cfg, (EGLNativeWindowType) &w->base, NULL);
    CHECK(surf != EGL_NO_SURFACE, "eglCreateWindowSurface 0x%x", eglGetError());
    if (surf == EGL_NO_SURFACE) return;
    CHECK(w->usage & GRALLOC_USAGE_SW_WRITE_OFTEN, "SW write usage requested");

    const EGLint ctxattr[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
    EGLContext ctx = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, ctxattr);
    CHECK(ctx != EGL_NO_CONTEXT, "eglCreateContext 0x%x", eglGetError());
    CHECK(eglMakeCurrent(dpy, surf, surf, ctx), "eglMakeCurrent 0x%x", eglGetError());
    printf("   GL_RENDERER=%s GL_VERSION=%s\n", glGetString(GL_RENDERER), glGetString(GL_VERSION));

    for (int frame = 0; frame < 3; frame++) {
        draw_frame(frame == 0);
        CHECK(eglSwapBuffers(dpy, surf), "eglSwapBuffers frame %d: 0x%x", frame, eglGetError());
        CHECK(w->queued == frame + 1, "frame %d queued=%d", frame, w->queued);
        const unsigned char *px = (const unsigned char *) w->buf[w->last_queued].handle;
        int stride = w->buf[w->last_queued].stride;
        if (bpp == 4) {
            const unsigned char *center = px + ((24) * stride + 32) * 4;
            const unsigned char *corner = px + (2 * stride + 2) * 4;
            int rgba = (format == HAL_PIXEL_FORMAT_RGBA_8888 || format == HAL_PIXEL_FORMAT_RGBX_8888);
            /* green square: G=255 only; blue background: B=255 only (R/B order depends on the format) */
            CHECK(center[1] == 255 && center[0] == 0 && center[2] == 0, "centre pixel %d,%d,%d,%d", center[0], center[1], center[2], center[3]);
            if (rgba) CHECK(corner[0] == 0 && corner[1] == 0 && corner[2] == 255, "corner RGBA %d,%d,%d,%d", corner[0], corner[1], corner[2], corner[3]);
            else      CHECK(corner[2] == 0 && corner[1] == 0 && corner[0] == 255, "corner BGRA %d,%d,%d,%d", corner[0], corner[1], corner[2], corner[3]);
            CHECK(corner[3] == 255, "alpha %d", corner[3]);
        } else {
            const unsigned short *c = (const unsigned short *) px;
            CHECK(c[24 * stride + 32] == 0x07e0, "565 centre 0x%04x", c[24 * stride + 32]);
            CHECK(c[2 * stride + 2] == 0x001f, "565 corner 0x%04x", c[2 * stride + 2]);
        }
    }
    CHECK(w->dequeued == w->queued + w->busy[0] + w->busy[1] + w->busy[2] + w->cancelled, "dequeue/queue balance");
    CHECK(g_locked == 0, "gralloc lock/unlock balanced (%d)", g_locked);

    eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    eglDestroySurface(dpy, surf);
    eglDestroyContext(dpy, ctx);
    CHECK(w->busy[0] + w->busy[1] + w->busy[2] == 0, "no buffer left dequeued after destroy");
    CHECK(w->refs == 0, "window refcount balanced (%d)", w->refs);
}

static void test_pbuffer(EGLDisplay dpy)
{
    printf("-- pbuffer + surfaceless readback\n");
    EGLConfig cfg = choose(dpy, HAL_PIXEL_FORMAT_RGBA_8888, EGL_PBUFFER_BIT);
    CHECK(cfg != NULL, "no pbuffer config");
    if (!cfg) return;
    const EGLint pb[] = { EGL_WIDTH, 32, EGL_HEIGHT, 32, EGL_NONE };
    EGLSurface surf = eglCreatePbufferSurface(dpy, cfg, pb);
    CHECK(surf != EGL_NO_SURFACE, "pbuffer 0x%x", eglGetError());
    const EGLint ctxattr[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
    EGLContext ctx = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, ctxattr);
    CHECK(eglMakeCurrent(dpy, surf, surf, ctx), "make current pbuffer");
    draw_frame(1);
    unsigned char px[4] = {0};
    glReadPixels(16, 16, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
    CHECK(px[0] == 0 && px[1] == 255 && px[2] == 0 && px[3] == 255, "glReadPixels centre %d,%d,%d,%d", px[0], px[1], px[2], px[3]);
    glReadPixels(1, 1, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
    CHECK(px[0] == 0 && px[1] == 0 && px[2] == 255, "glReadPixels corner %d,%d,%d", px[0], px[1], px[2]);
    eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);

    /* Chrome/Firefox use surfaceless contexts. */
    const char *ext = eglQueryString(dpy, EGL_EXTENSIONS);
    CHECK(ext && strstr(ext, "EGL_KHR_surfaceless_context"), "EGL_KHR_surfaceless_context advertised");
    CHECK(eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx), "surfaceless make current");
    eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    eglDestroyContext(dpy, ctx);
    eglDestroySurface(dpy, surf);
}

int main(void)
{
    kobo_fake_set_gralloc(&g_gralloc.common);
    EGLDisplay dpy = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    EGLint major = 0, minor = 0;
    CHECK(dpy != EGL_NO_DISPLAY, "eglGetDisplay");
    CHECK(eglInitialize(dpy, &major, &minor), "eglInitialize 0x%x", eglGetError());
    printf("EGL %d.%d vendor=%s\n", major, minor, eglQueryString(dpy, EGL_VENDOR));
    CHECK(eglBindAPI(EGL_OPENGL_ES_API), "bind ES");

    test_window(dpy, HAL_PIXEL_FORMAT_RGBA_8888, 4, "RGBA_8888");
    test_window(dpy, HAL_PIXEL_FORMAT_RGBX_8888, 4, "RGBX_8888");
    test_window(dpy, HAL_PIXEL_FORMAT_BGRA_8888, 4, "BGRA_8888");
    test_window(dpy, HAL_PIXEL_FORMAT_RGB_565, 2, "RGB_565");
    test_pbuffer(dpy);

    eglTerminate(dpy);
    CHECK(g_lock_calls == g_unlock_calls, "lock/unlock calls %d/%d", g_lock_calls, g_unlock_calls);
    printf(failures ? "RESULT: %d FAILURE(S)\n" : "RESULT: OK\n", failures);
    return failures ? 1 : 0;
}
