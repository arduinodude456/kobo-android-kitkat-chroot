/* SPDX-License-Identifier: MIT
 * On-device check of the GLES2 stack: run inside the chroot with the shim
 * preloaded, e.g.  sh android.sh exec /system/bin/kobo-gles-test
 * Exit status 0 means: EGL initialised, a GLES2 context exists, a clear
 * colour round-trips through glReadPixels. */
#include <EGL/egl.h>
#include <GLES2/gl2.h>
#include <stdio.h>

int main(void)
{
    EGLDisplay d = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    EGLint maj = 0, min = 0, n = 0;
    const EGLint ca[] = { EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT, EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
                          EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_NONE };
    const EGLint pa[] = { EGL_WIDTH, 16, EGL_HEIGHT, 16, EGL_NONE };
    const EGLint xa[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
    EGLConfig c;
    unsigned char px[4] = { 0 };

    if (!eglInitialize(d, &maj, &min)) { puts("FAIL eglInitialize"); return 1; }
    printf("EGL %d.%d vendor=%s\n", maj, min, eglQueryString(d, EGL_VENDOR));
    if (!eglChooseConfig(d, ca, &c, 1, &n) || n < 1) { puts("FAIL eglChooseConfig"); return 2; }
    EGLSurface s = eglCreatePbufferSurface(d, c, pa);
    EGLContext x = eglCreateContext(d, c, EGL_NO_CONTEXT, xa);
    if (s == EGL_NO_SURFACE || x == EGL_NO_CONTEXT || !eglMakeCurrent(d, s, s, x)) { puts("FAIL context"); return 3; }
    printf("GL_RENDERER=%s\nGL_VERSION=%s\n", glGetString(GL_RENDERER), glGetString(GL_VERSION));
    glClearColor(1.f, 0.f, 0.f, 1.f);
    glClear(GL_COLOR_BUFFER_BIT);
    glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
    printf("pixel=%u,%u,%u,%u\n", px[0], px[1], px[2], px[3]);
    if (px[0] != 255 || px[1] != 0 || px[2] != 0) { puts("FAIL readback"); return 4; }
    puts("OK");
    return 0;
}
