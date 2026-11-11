/*
 * ios_gl_tex_probe — isolate the CVOpenGLESTextureCache path used by
 * mpv's video/out/hwdec/hwdec_ios_gl.m.
 *
 * For an NV12 and a P010 CVPixelBuffer it tries the GL internal format /
 * format / type combinations that mpv can select (the GL_LUMINANCE workaround
 * and the GL_RED/GL_RG variants), reports which ones CVOpenGLESTextureCache
 * accepts, reads back GL_TEXTURE_INTERNAL_FORMAT, and renders one quad through
 * the same sampler layout mpv uses (Y=.r, UV=.ra for LUMINANCE_ALPHA or .rg
 * for RG).
 *
 * Build (simulator):
 *   xcrun -sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=17.0 \
 *     -fobjc-arc -framework OpenGLES -framework CoreVideo -framework Foundation \
 *     ios_gl_tex_probe.m -o ios_gl_tex_probe
 * Run:
 *   xcrun simctl spawn booted ./ios_gl_tex_probe
 *
 * This is a diagnostic for the LGPL build; it is not part of the app.
 */

#import <Foundation/Foundation.h>
#import <OpenGLES/ES3/gl.h>
#import <OpenGLES/ES3/glext.h>
#import <OpenGLES/EAGL.h>
#import <CoreVideo/CoreVideo.h>

#ifndef GL_R16_EXT
#define GL_R16_EXT 0x822D
#endif
#ifndef GL_RG16_EXT
#define GL_RG16_EXT 0x822F
#endif

static const int W = 64, H = 64;

static GLuint make_shader(GLenum type, const char *src)
{
    GLuint s = glCreateShader(type);
    glShaderSource(s, 1, &src, NULL);
    glCompileShader(s);
    GLint ok = 0;
    glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[512];
        glGetShaderInfoLog(s, sizeof(log), NULL, log);
        fprintf(stderr, "shader: %s\n", log);
    }
    return s;
}

static GLuint make_program(int la)
{
    const char *vs =
        "attribute vec2 a_pos;\n"
        "attribute vec2 a_uv;\n"
        "varying vec2 v_uv;\n"
        "void main() { v_uv = a_uv; gl_Position = vec4(a_pos, 0.0, 1.0); }\n";
    char fs[2048];
    snprintf(fs, sizeof(fs),
        "precision mediump float;\n"
        "varying vec2 v_uv;\n"
        "uniform sampler2D u_y;\n"
        "uniform sampler2D u_uv;\n"
        "void main() {\n"
        "  float y = texture2D(u_y, v_uv).r;\n"
        "  vec2 c = texture2D(u_uv, v_uv).%s;\n"
        "  float yy = (y - 16.0/255.0) * (255.0/219.0);\n"
        "  float cb = (c.x - 128.0/255.0) * (255.0/224.0);\n"
        "  float cr = (c.y - 128.0/255.0) * (255.0/224.0);\n"
        "  vec3 rgb = vec3(yy + 1.5748*cr,\n"
        "                  yy - 0.1873*cb - 0.4681*cr,\n"
        "                  yy + 1.8556*cb);\n"
        "  gl_FragColor = vec4(clamp(rgb, 0.0, 1.0), 1.0);\n"
        "}\n", la ? "ra" : "rg");
    GLuint p = glCreateProgram();
    glAttachShader(p, make_shader(GL_VERTEX_SHADER, vs));
    glAttachShader(p, make_shader(GL_FRAGMENT_SHADER, fs));
    glBindAttribLocation(p, 0, "a_pos");
    glBindAttribLocation(p, 1, "a_uv");
    glLinkProgram(p);
    GLint ok = 0;
    glGetProgramiv(p, GL_LINK_STATUS, &ok);
    if (!ok) {
        char log[512];
        glGetProgramInfoLog(p, sizeof(log), NULL, log);
        fprintf(stderr, "link: %s\n", log);
    }
    return p;
}

typedef struct {
    const char *name;
    GLint internal;
    GLenum format;
    GLenum type;
    int la;
} variant;

static int try_variant(CVOpenGLESTextureCacheRef cache, CVPixelBufferRef pb,
                       int plane, const variant *v, int w, int h,
                       int draw, GLuint ytex, GLuint uvtex)
{
    CVOpenGLESTextureRef tex = NULL;
    CVReturn err = CVOpenGLESTextureCacheCreateTextureFromImage(
        kCFAllocatorDefault, cache, pb, NULL, GL_TEXTURE_2D,
        v->internal, w, h, v->format, v->type, plane, &tex);
    if (err != kCVReturnSuccess || !tex) {
        printf("  %-22s plane=%d internal=0x%04x format=0x%04x type=0x%04x -> err=%d\n",
               v->name, plane, v->internal, v->format, v->type, (int)err);
        return -1;
    }

    GLuint name = CVOpenGLESTextureGetName(tex);
    glBindTexture(GL_TEXTURE_2D, name);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    printf("  %-22s plane=%d internal=0x%04x format=0x%04x type=0x%04x -> ok tex=%u %dx%d\n",
           v->name, plane, v->internal, v->format, v->type, name, w, h);

    if (draw && plane == 0)
        ytex = name;
    if (draw && plane == 1)
        uvtex = name;

    if (draw && plane == 1 && ytex && uvtex) {
        GLuint prog = make_program(v->la);
        glUseProgram(prog);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, ytex);
        glActiveTexture(GL_TEXTURE1);
        glBindTexture(GL_TEXTURE_2D, uvtex);
        glUniform1i(glGetUniformLocation(prog, "u_y"), 0);
        glUniform1i(glGetUniformLocation(prog, "u_uv"), 1);

        static const GLfloat verts[] = {
            -1, -1, 0, 0,  1, -1, 1, 0,  -1, 1, 0, 1,
            -1,  1, 0, 1,  1, -1, 1, 0,   1, 1, 1, 1,
        };
        GLuint vbo;
        glGenBuffers(1, &vbo);
        glBindBuffer(GL_ARRAY_BUFFER, vbo);
        glBufferData(GL_ARRAY_BUFFER, sizeof(verts), verts, GL_STATIC_DRAW);
        glEnableVertexAttribArray(0);
        glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(GLfloat), 0);
        glEnableVertexAttribArray(1);
        glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(GLfloat),
                              (void *)(2 * sizeof(GLfloat)));
        glDrawArrays(GL_TRIANGLES, 0, 6);
        glFinish();

        unsigned char px[4] = {0};
        glReadPixels(W / 2, H / 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
        printf("    sampled center = %u,%u,%u,%u (expected ~128,128,128)\n",
               px[0], px[1], px[2], px[3]);
        glDeleteProgram(prog);
        glDeleteBuffers(1, &vbo);
    }

    CFRelease(tex);
    return 0;
}

static void run_format(NSString *label, OSType pixfmt, int depth)
{
    printf("== %s (0x%08x, %d-bit)\n", label.UTF8String, (unsigned)pixfmt, depth);
    NSDictionary *attrs = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferOpenGLESCompatibilityKey: @YES,
    };
    CVPixelBufferRef pb = NULL;
    CVReturn err = CVPixelBufferCreate(kCFAllocatorDefault, W, H, pixfmt,
                                       (__bridge CFDictionaryRef)attrs, &pb);
    if (err != kCVReturnSuccess || !pb) {
        printf("  CVPixelBufferCreate -> %d\n", (int)err);
        return;
    }

    CVPixelBufferLockBaseAddress(pb, 0);
    if (depth == 8) {
        memset(CVPixelBufferGetBaseAddressOfPlane(pb, 0), 100,
               CVPixelBufferGetBytesPerRowOfPlane(pb, 0) * H);
        uint8_t *uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1);
        size_t stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
        for (int y = 0; y < H / 2; y++)
            memset(uv + y * stride, 128, W);
    } else {
        uint16_t *y = CVPixelBufferGetBaseAddressOfPlane(pb, 0);
        size_t ys = CVPixelBufferGetBytesPerRowOfPlane(pb, 0) / 2;
        for (int r = 0; r < H; r++)
            for (int c = 0; c < W; c++)
                y[r * ys + c] = 400; // ~limited 100 IRE in 10-bit
        uint16_t *uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1);
        size_t us = CVPixelBufferGetBytesPerRowOfPlane(pb, 1) / 2;
        for (int r = 0; r < H / 2; r++)
            for (int c = 0; c < W; c++)
                uv[r * us + c] = 512;
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);

    CVOpenGLESTextureCacheRef cache = NULL;
    err = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL,
                                       [EAGLContext currentContext], NULL, &cache);
    printf("  texture cache create -> %d\n", (int)err);
    if (err != kCVReturnSuccess || !cache) {
        CVPixelBufferRelease(pb);
        return;
    }

    if (depth == 8) {
        variant yvars[] = {
            {"LUMINANCE/u8", GL_LUMINANCE, GL_LUMINANCE, GL_UNSIGNED_BYTE, 0},
            {"R8/RED/u8", GL_R8, GL_RED, GL_UNSIGNED_BYTE, 0},
            {"RED/RED/u8", GL_RED, GL_RED, GL_UNSIGNED_BYTE, 0},
        };
        variant uvars[] = {
            {"LUMINANCE_ALPHA/u8", GL_LUMINANCE_ALPHA, GL_LUMINANCE_ALPHA, GL_UNSIGNED_BYTE, 1},
            {"RG8/RG/u8", GL_RG8, GL_RG, GL_UNSIGNED_BYTE, 1},
            {"RG/RG/u8", GL_RG, GL_RG, GL_UNSIGNED_BYTE, 1},
        };
        for (int i = 0; i < 3; i++)
            try_variant(cache, pb, 0, &yvars[i], W, H, 0, 0, 0);
        for (int i = 0; i < 3; i++)
            try_variant(cache, pb, 1, &uvars[i], W / 2, H / 2, 0, 0, 0);
        /* Run each pair in its own pass so the draw uses that pair. */
        for (int i = 0; i < 3; i++) {
            for (int j = 0; j < 3; j++) {
                printf("  pair y=%s uv=%s\n", yvars[i].name, uvars[j].name);
                CVOpenGLESTextureRef yt = NULL, ut = NULL;
                GLuint ytex = 0, uvtex = 0;
                if (CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, NULL,
                        GL_TEXTURE_2D, yvars[i].internal, W, H, yvars[i].format, yvars[i].type, 0, &yt) == 0) {
                    ytex = CVOpenGLESTextureGetName(yt);
                    glBindTexture(GL_TEXTURE_2D, ytex);
                    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
                    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
                }
                if (CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, NULL,
                        GL_TEXTURE_2D, uvars[j].internal, W / 2, H / 2, uvars[j].format, uvars[j].type, 1, &ut) == 0) {
                    uvtex = CVOpenGLESTextureGetName(ut);
                    glBindTexture(GL_TEXTURE_2D, uvtex);
                    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
                    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
                }
                if (ytex && uvtex) {
                    GLuint prog = make_program(uvars[j].la);
                    glUseProgram(prog);
                    glActiveTexture(GL_TEXTURE0);
                    glBindTexture(GL_TEXTURE_2D, ytex);
                    glActiveTexture(GL_TEXTURE1);
                    glBindTexture(GL_TEXTURE_2D, uvtex);
                    glUniform1i(glGetUniformLocation(prog, "u_y"), 0);
                    glUniform1i(glGetUniformLocation(prog, "u_uv"), 1);
                    static const GLfloat verts[] = {
                        -1, -1, 0, 0,  1, -1, 1, 0,  -1, 1, 0, 1,
                        -1,  1, 0, 1,  1, -1, 1, 0,   1, 1, 1, 1,
                    };
                    GLuint vbo;
                    glGenBuffers(1, &vbo);
                    glBindBuffer(GL_ARRAY_BUFFER, vbo);
                    glBufferData(GL_ARRAY_BUFFER, sizeof(verts), verts, GL_STATIC_DRAW);
                    glEnableVertexAttribArray(0);
                    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(GLfloat), 0);
                    glEnableVertexAttribArray(1);
                    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(GLfloat),
                                          (void *)(2 * sizeof(GLfloat)));
                    glDrawArrays(GL_TRIANGLES, 0, 6);
                    glFinish();
                    unsigned char px[4] = {0};
                    glReadPixels(W / 2, H / 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
                    printf("    sampled center = %u,%u,%u,%u\n", px[0], px[1], px[2], px[3]);
                    glDeleteProgram(prog);
                    glDeleteBuffers(1, &vbo);
                } else {
                    printf("    (pair not created)\n");
                }
                if (yt) CFRelease(yt);
                if (ut) CFRelease(ut);
            }
        }
    } else {
        variant yvars[] = {
            {"LUMINANCE/u16", GL_LUMINANCE, GL_LUMINANCE, GL_UNSIGNED_SHORT, 0},
            {"R16_EXT/RED/u16", GL_R16_EXT, GL_RED, GL_UNSIGNED_SHORT, 0},
        };
        variant uvars[] = {
            {"LUMINANCE_ALPHA/u16", GL_LUMINANCE_ALPHA, GL_LUMINANCE_ALPHA, GL_UNSIGNED_SHORT, 1},
            {"RG16_EXT/RG/u16", GL_RG16_EXT, GL_RG, GL_UNSIGNED_SHORT, 1},
        };
        for (int i = 0; i < 2; i++)
            try_variant(cache, pb, 0, &yvars[i], W, H, 0, 0, 0);
        for (int i = 0; i < 2; i++)
            try_variant(cache, pb, 1, &uvars[i], W / 2, H / 2, 0, 0, 0);
    }

    CVOpenGLESTextureCacheFlush(cache, 0);
    CFRelease(cache);
    CVPixelBufferRelease(pb);
}

int main(void)
{
    @autoreleasepool {
        EAGLContext *ctx = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3];
        if (!ctx) {
            fprintf(stderr, "no ES3 context\n");
            return 1;
        }
        [EAGLContext setCurrentContext:ctx];

        GLuint fbo_tex, fbo;
        glGenTextures(1, &fbo_tex);
        glBindTexture(GL_TEXTURE_2D, fbo_tex);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, W, H, 0, GL_RGBA,
                     GL_UNSIGNED_BYTE, NULL);
        glGenFramebuffers(1, &fbo);
        glBindFramebuffer(GL_FRAMEBUFFER, fbo);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                               GL_TEXTURE_2D, fbo_tex, 0);
        if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE)
            printf("FBO incomplete\n");
        glViewport(0, 0, W, H);

        printf("GL_RENDERER=%s\nGL_VERSION=%s\n",
               glGetString(GL_RENDERER), glGetString(GL_VERSION));

        run_format(@"NV12 video-range", kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 8);
        run_format(@"P010 video-range", kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, 10);
    }
    return 0;
}
