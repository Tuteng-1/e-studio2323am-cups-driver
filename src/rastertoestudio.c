/*
 * rastertoestudio.c — TOSHIBA e-STUDIO2323AM / 2823AM 原生 CUPS filter
 *
 * 输入：CUPS raster（cgpdftoraster 等产出，600dpi）
 * 输出：PJL 信封 + JBIG-1 位图（设备 GDI 引擎实际使用的线缆协议）
 *
 * 协议来自实体 Windows 驱动的抓包（eSTUDIO2323AM-captures/）：
 *
 *   ESC%-12345X@PJL
 *   @PJL SET TIMESTAMP=...
 *   @PJL SET COMPRESS=JBIG
 *   @PJL SET USERNAME=...
 *   ...
 *   @PJL SET PAGESTATUS=START
 *   @PJL SET PAPER=A4
 *   @PJL SET PAPERWIDTH=4961
 *   @PJL SET PAPERLENGTH=7016
 *   @PJL SET RESOLUTION=600
 *   @PJL SET ORIENTATION=PORTRAIT
 *   @PJL SET IMAGELEN=130
 *   <20 字节 BIH + JBIG 数据，每 65536 字节切一块>
 *   @PJL SET DOTCOUNT=0
 *   @PJL SET PAGESTATUS=END
 *   @PJL EOJ
 *   ESC%-12345X
 *
 * 构建：make        安装：sudo make install
 */

#include <cups/cups.h>
#include <cups/raster.h>

#include <errno.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "estudio_jbig.h"

#define UEL "\x1b%-12345X"
#define ENGINE_DPI 600
#define IMAGE_CHUNK 65536UL

/* ---------------------------------------------------------------- 输出 */

static unsigned char *outbuf;
static size_t outlen, outcap;
static int debug;

static void out_flush(void)
{
    size_t off = 0;

    while (off < outlen) {
        ssize_t n = write(STDOUT_FILENO, outbuf + off, outlen - off);

        if (n <= 0) {
            if (n < 0 && errno == EINTR)
                continue;
            fprintf(stderr, "ERROR: write: %s\n", strerror(errno));
            exit(1);
        }
        off += (size_t)n;
    }
    outlen = 0;
}

static void out(const void *p, size_t n)
{
    if (outlen + n > outcap) {
        size_t cap = outcap ? outcap : 65536;
        unsigned char *nb;

        while (cap < outlen + n)
            cap *= 2;
        nb = realloc(outbuf, cap);
        if (!nb) {
            fprintf(stderr, "ERROR: out of memory\n");
            exit(1);
        }
        outbuf = nb;
        outcap = cap;
    }
    memcpy(outbuf + outlen, p, n);
    outlen += n;
    if (outlen >= 262144)
        out_flush();
}

static void outs(const char *s) { out(s, strlen(s)); }

static void outf(const char *fmt, ...)
{
    char buf[1024];
    va_list ap;
    int n;

    va_start(ap, fmt);
    n = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (n < 0)
        return;
    if ((size_t)n >= sizeof(buf))
        n = (int)sizeof(buf) - 1;
    out(buf, (size_t)n);
}

static void dbg(const char *fmt, ...)
{
    va_list ap;

    if (!debug)
        return;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
}

/* ---------------------------------------------------------------- 选项 */

static int get_opt(const char *opts, const char *name, char *buf, size_t buflen)
{
    const char *p = opts;
    size_t n = strlen(name);

    while (p && *p) {
        while (*p == ' ' || *p == '\t')
            p++;
        if (!strncmp(p, name, n) && p[n] == '=') {
            const char *v = p + n + 1;
            size_t l = strcspn(v, " \t");

            if (l >= buflen)
                l = buflen - 1;
            memcpy(buf, v, l);
            buf[l] = 0;
            return 1;
        }
        p = strchr(p, ' ');
    }
    return 0;
}

static int opt_is(const char *opts, const char *name, const char *value)
{
    char buf[128];

    return get_opt(opts, name, buf, sizeof(buf)) && !strcmp(buf, value);
}

/* ---------------------------------------------------------------- 纸张 */

struct paper {
    const char *opt;    /* PPD *PageSize 取值 */
    const char *pjl;    /* 设备 @PJL SET PAPER= 的拼写（取自 eSSh6OCM.dll） */
    double w_mm;
    double h_mm;
};

static const struct paper papers[] = {
    { "A4",        "A4",         210.0,   297.0   },
    { "A5",        "A5",         148.0,   210.0   },
    { "A3",        "A3",         297.0,   420.0   },
    { "B4",        "JISB4",      257.0,   364.0   },
    { "B5",        "JISB5",      182.0,   257.0   },
    { "Letter",    "LETTER",     215.9,   279.4   },
    { "Legal",     "LEGAL",      215.9,   355.6   },
    { "Tabloid",   "LEDGER",     279.4,   431.8   },
    { "Ledger",    "LEDGER",     279.4,   431.8   },
    { "Statement", "INVOICE",    139.7,   215.9   },
    { "FanFoldGermanLegal", "13LG", 215.9, 330.2   },
    { "13LG",      "13LG",       215.9,   330.2   },
    { "Env10",     "ENV_10",     104.8,   241.3   },
    { "EnvDL",     "ENV_DL",     110.0,   220.0   },
    { "EnvC5",     "ENV_C5",     162.0,   229.0   },
    { "EnvMonarch","ENV_MONARCH", 98.4,   190.5   },
    { "Postcard",  "JPOST",      100.0,   148.0   },
    { "JPOST",     "JPOST",      100.0,   148.0   },
    { "8.5x8.5",   "85SQ",       215.9,   216.1   },
    { "SQ85",      "85SQ",       215.9,   216.1   },
};

static const struct paper *find_paper(const char *opts)
{
    char name[64];
    size_t i;

    if (!get_opt(opts, "PageSize", name, sizeof(name)))
        strcpy(name, "A4");

    for (i = 0; i < sizeof(papers) / sizeof(papers[0]); i++)
        if (!strcmp(name, papers[i].opt))
            return &papers[i];

    /* 未知纸型：交给调用者按 raster 实际尺寸处理 */
    return NULL;
}

static int mm_to_px(double mm) { return (int)(mm / 25.4 * ENGINE_DPI + 0.5); }

/* ---------------------------------------------------------------- 位图 */

/* 8x8 Bayer 有序抖动矩阵（0..63），仅用于 8bpp/彩色输入 */
static const int bayer8[8][8] = {
    { 0, 32,  8, 40,  2, 34, 10, 42},
    {48, 16, 56, 24, 50, 18, 58, 26},
    {12, 44,  4, 36, 14, 46,  6, 38},
    {60, 28, 52, 20, 62, 30, 54, 22},
    { 3, 35, 11, 43,  1, 33,  9, 41},
    {51, 19, 59, 27, 49, 17, 57, 25},
    {15, 47,  7, 39, 13, 45,  5, 37},
    {63, 31, 55, 23, 61, 29, 53, 21},
};

static inline void set_bit(unsigned char *row, int x)
{
    row[x >> 3] |= (unsigned char)(0x80 >> (x & 7));
}

static inline int get_bit(const unsigned char *row, int x)
{
    return (row[x >> 3] >> (7 - (x & 7))) & 1;
}

/*
 * 把 CUPS raster 的像素行转成 1bpp "黑=1" 行。
 * cs 为 CUPS 色彩空间：K=3、W=0、RGB/SRGB=1/18...、GRAYE=8。
 */
static void row_to_mono(const unsigned char *src, int width, int y, int bpp,
                        int cs, unsigned char *dst)
{
    int x;

    memset(dst, 0, (size_t)((width + 7) / 8));

    switch (bpp) {
    case 1:
        for (x = 0; x < width; x++) {
            int bit = get_bit(src, x);

            if (cs == CUPS_CSPACE_W || cs == CUPS_CSPACE_SW)
                bit ^= 1;
            if (bit)
                set_bit(dst, x);
        }
        break;

    case 8: {
        int invert = (cs == CUPS_CSPACE_W || cs == CUPS_CSPACE_SW);

        for (x = 0; x < width; x++) {
            int v = invert ? 255 - src[x] : src[x];
            int thr = bayer8[y & 7][x & 7] * 4;   /* 0..252 */

            if (v > thr)
                set_bit(dst, x);
        }
        break;
    }

    case 24:
    case 32: {
        int step = bpp / 8;

        for (x = 0; x < width; x++) {
            const unsigned char *p = src + (size_t)x * step;
            int lum = (p[0] * 77 + p[1] * 150 + p[2] * 29) >> 8;
            int thr = bayer8[y & 7][x & 7] * 4;

            if (255 - lum > thr)
                set_bit(dst, x);
        }
        break;
    }

    default:
        for (x = 0; x < width; x++)
            if (src[x] > 128)
                set_bit(dst, x);
        break;
    }
}

/*
 * 把整页 raster 读进来，转换成 1bpp 单色图。
 */
static unsigned char *read_mono(cups_raster_t *ras, const cups_page_header2_t *hdr,
                                int *out_w, int *out_h)
{
    int w = (int)hdr->cupsWidth;
    int h = (int)hdr->cupsHeight;
    size_t stride = (size_t)((w + 7) / 8);
    unsigned char *mono, *line, *row;
    int y;

    mono = malloc(stride * (size_t)h + 1);
    line = malloc(hdr->cupsBytesPerLine + 16);
    row = malloc(stride + 16);
    if (!mono || !line || !row) {
        fprintf(stderr, "ERROR: out of memory (page %dx%d)\n", w, h);
        exit(1);
    }

    for (y = 0; y < h; y++) {
        if (cupsRasterReadPixels(ras, line, hdr->cupsBytesPerLine) !=
            hdr->cupsBytesPerLine) {
            fprintf(stderr, "ERROR: short raster read at line %d of %d\n", y, h);
            exit(1);
        }
        row_to_mono(line, w, y, (int)hdr->cupsBitsPerPixel,
                    (int)hdr->cupsColorSpace, row);
        memcpy(mono + (size_t)y * stride, row, stride);
    }

    free(line);
    free(row);

    *out_w = w;
    *out_h = h;
    return mono;
}

/* 顺时针 90° 转置不需要，这里按抓包实测的方向：dest(x,y) = src(y, h-1-x) */
static unsigned char *rotate_mono(const unsigned char *src, int w, int h)
{
    size_t dstride = (size_t)((h + 7) / 8);
    size_t sstride = (size_t)((w + 7) / 8);
    unsigned char *dst = calloc(dstride * (size_t)w + 1, 1);
    int x, y;

    if (!dst) {
        fprintf(stderr, "ERROR: out of memory (rotate)\n");
        exit(1);
    }

    for (y = 0; y < w; y++) {
        unsigned char *drow = dst + (size_t)y * dstride;
        int sx = w - 1 - y;

        for (x = 0; x < h; x++)
            if (get_bit(src + (size_t)x * sstride, sx))
                set_bit(drow, x);
    }

    return dst;
}

/* 最近邻缩放：分辨率不符、或 raster 比目标纸面大时用 */
static unsigned char *scale_mono(const unsigned char *src, int sw, int sh,
                                 int dw, int dh)
{
    size_t dstride = (size_t)((dw + 7) / 8);
    size_t sstride = (size_t)((sw + 7) / 8);
    unsigned char *dst = calloc(dstride * (size_t)dh + 1, 1);
    int x, y;

    if (!dst) {
        fprintf(stderr, "ERROR: out of memory (scale %dx%d)\n", dw, dh);
        exit(1);
    }

    for (y = 0; y < dh; y++) {
        int sy = (int)((long long)y * sh / dh);
        const unsigned char *srow = src + (size_t)sy * sstride;
        unsigned char *drow = dst + (size_t)y * dstride;

        for (x = 0; x < dw; x++) {
            int sx = (int)((long long)x * sw / dw);

            if (get_bit(srow, sx))
                set_bit(drow, x);
        }
    }

    return dst;
}

/*
 * 把单色图贴到整页位图的中间（CUPS 的 raster 只覆盖可打印区），
 * 返回整页位图并统计黑像素数。
 */
static unsigned char *compose_page(const unsigned char *mono, int mw, int mh,
                                   int page_w, int page_h, unsigned long *dots)
{
    size_t stride = (size_t)((page_w + 7) / 8);
    unsigned char *page = calloc(stride * (size_t)page_h + 1, 1);
    size_t mstride = (size_t)((mw + 7) / 8);
    int off_x = (page_w - mw) / 2;
    int off_y = (page_h - mh) / 2;
    unsigned long count = 0;
    int x, y;

    if (!page) {
        fprintf(stderr, "ERROR: out of memory (page %dx%d)\n", page_w, page_h);
        exit(1);
    }
    if (off_x < 0)
        off_x = 0;
    if (off_y < 0)
        off_y = 0;

    for (y = 0; y < mh; y++) {
        const unsigned char *srow = mono + (size_t)y * mstride;
        unsigned char *drow;
        int maxx;

        if (off_y + y >= page_h)
            break;                      /* 防御：绝不越界写 */
        drow = page + (size_t)(off_y + y) * stride;
        maxx = page_w - off_x;
        if (maxx > mw)
            maxx = mw;

        for (x = 0; x < maxx; x++) {
            if (get_bit(srow, x)) {
                set_bit(drow, off_x + x);
                count++;
            }
        }
    }

    *dots = count;
    return page;
}

/* ---------------------------------------------------------------- PJL */

static void emit_job_header(const char *user, int first, int toner_save,
                            int smoothing)
{
    char stamp[64];
    time_t now = time(NULL);
    struct tm tmv;

    outs(UEL "@PJL\r\n");

    if (first) {
        localtime_r(&now, &tmv);
        strftime(stamp, sizeof(stamp), "%Y/%m/%d %H:%M:%S", &tmv);
        outf("@PJL SET TIMESTAMP=%s\r\n", stamp);
    }

    outs("@PJL SET COMPRESS=JBIG\r\n");
    outf("@PJL SET USERNAME=%s\r\n", user);
    outs("@PJL SET COVER=OFF\r\n");
    outs("@PJL SET HOLD=OFF\r\n");
    outs("@PJL SET ROTATESORT=OFF\r\n");
    outf("@PJL SET SMOOTHING=%s\r\n", smoothing ? "ON" : "OFF");
    outf("@PJL SET TONERSAVE=%s\r\n", toner_save ? "ON" : "OFF");
    outs("@PJL SET DEPTCODENUM=\"\"\r\n");
}

struct page {
    unsigned char *bie;
    size_t len;
    unsigned long dots;
    int width;
    int height;
    int landscape;
    const char *pjl_paper;   /* NULL -> CUSTOM */
};

static void emit_page(const struct page *p, const char *media_source,
                      const char *media_type)
{
    outs("@PJL SET MEDIASOURCE=");
    outs(media_source);
    outs("\r\n");
    outf("@PJL SET MEDIATYPE=%s\r\n", media_type);
    outs("@PJL SET PAGESTATUS=START\r\n");
    outs("@PJL SET COPIES=1\r\n");
    /* 2323AM/2823AM 无自动双面单元：始终单面，和 Windows 驱动抓包一致 */
    outs("@PJL SET DUPLEX=OFF\r\n");
    outf("@PJL SET PAPER=%s\r\n", p->pjl_paper ? p->pjl_paper : "CUSTOM");
    outf("@PJL SET PAPERWIDTH=%d\r\n", p->width);
    outf("@PJL SET PAPERLENGTH=%d\r\n", p->height);
    outs("@PJL SET RESOLUTION=600\r\n");
    outf("@PJL SET ORIENTATION=%s\r\n", p->landscape ? "LANDSCAPE" : "PORTRAIT");

    {
        size_t off = 0;

        while (off < p->len) {
            size_t chunk = p->len - off;

            /* 抓包：首块 20 + 65536，其余每块 65536 */
            if (off == 0) {
                if (chunk > IMAGE_CHUNK + 20)
                    chunk = IMAGE_CHUNK + 20;
            } else if (chunk > IMAGE_CHUNK) {
                chunk = IMAGE_CHUNK;
            }

            outf("@PJL SET IMAGELEN=%lu\r\n", (unsigned long)chunk);
            out(p->bie + off, chunk);
            off += chunk;
        }
    }

    outf("@PJL SET DOTCOUNT=%lu\r\n", p->dots);
    outs("@PJL SET PAGESTATUS=END\r\n");
}

/* ---------------------------------------------------------------- main */

static void usage(const char *prog)
{
    fprintf(stderr, "usage: %s job-id user title copies options [file]\n", prog);
}

static void sanitize_user(char *dst, size_t dstlen, const char *src)
{
    size_t i;

    if (!src || !*src)
        src = "cups";

    for (i = 0; i + 1 < dstlen && src[i]; i++) {
        unsigned char c = (unsigned char)src[i];

        dst[i] = (c < 0x20 || c == 0x7f || c == ' ' || c == '\\' || c == '"') ? '_' : (char)c;
    }
    dst[i] = 0;

    if (!dst[0])
        snprintf(dst, dstlen, "cups");
}

int main(int argc, char *argv[])
{
    const char *user_arg, *opts;
    const char *path;
    const struct paper *paper;
    char username[64];
    char media_source[32] = "AUTO";
    char media_type[32] = "PAPER";
    int toner_save = 0, smoothing = 0, copies;
    struct page *pages = NULL;
    size_t npages = 0, pagecap = 0;
    cups_raster_t *ras;
    cups_page_header2_t hdr;
    FILE *in = stdin;
    char kw[64];
    size_t i;

    if (argc < 6) {
        usage(argv[0]);
        return 1;
    }

    user_arg = argv[2];
    opts = argv[5];
    path = (argc > 6) ? argv[6] : NULL;

    debug = getenv("ESTUDIO_DEBUG") != NULL;
    sanitize_user(username, sizeof(username), user_arg);

    copies = atoi(argv[4]);
    if (copies < 1)
        copies = 1;

    {
        char res[64];

        if (get_opt(opts, "Resolution", res, sizeof(res)) && strcmp(res, "600dpi"))
            fprintf(stderr, "WARNING: Resolution=%s ignored, engine runs at 600dpi\n", res);
    }

    if (get_opt(opts, "InputSlot", kw, sizeof(kw))) {
        if (!strcmp(kw, "Tray1"))
            strcpy(media_source, "TRAY1");
        else if (!strcmp(kw, "Tray2"))
            strcpy(media_source, "TRAY2");
        else if (!strcmp(kw, "Bypass"))
            strcpy(media_source, "MANUALFEED");
        else
            strcpy(media_source, "AUTO");
    }

    if (get_opt(opts, "MediaType", kw, sizeof(kw))) {
        if (!strcmp(kw, "Thin"))
            strcpy(media_type, "THIN");
        else if (!strcmp(kw, "Thick"))
            strcpy(media_type, "THICK");
        else if (!strcmp(kw, "Envelope"))
            strcpy(media_type, "ENVELOPE");
        else if (!strcmp(kw, "Transparency"))
            strcpy(media_type, "TRANSPARENCY");
        else if (!strcmp(kw, "Recycle"))
            strcpy(media_type, "RECYCLE");
        else
            strcpy(media_type, "PAPER");
    }

    if (opt_is(opts, "TonerSave", "True"))
        toner_save = 1;
    if (opt_is(opts, "Smoothing", "True"))
        smoothing = 1;

    paper = find_paper(opts);

    if (path && strcmp(path, "-") != 0) {
        in = fopen(path, "rb");
        if (!in) {
            fprintf(stderr, "ERROR: cannot open %s: %s\n", path, strerror(errno));
            return 1;
        }
    }

    ras = cupsRasterOpen(fileno(in), CUPS_RASTER_READ);
    if (!ras) {
        fprintf(stderr, "ERROR: not a CUPS raster stream\n");
        return 1;
    }

    while (cupsRasterReadHeader2(ras, &hdr)) {
        unsigned char *mono, *page_bits, *bie = NULL;
        size_t bie_len = 0;
        int mw, mh, page_w, page_h, landscape = 0;
        int res = (int)hdr.HWResolution[0];
        unsigned long dots = 0;

        if (res <= 0)
            res = ENGINE_DPI;

        mono = read_mono(ras, &hdr, &mw, &mh);

        if (res != ENGINE_DPI) {
            int nw = (int)((long long)mw * ENGINE_DPI / res + 0.5);
            int nh = (int)((long long)mh * ENGINE_DPI / res + 0.5);
            unsigned char *big = scale_mono(mono, mw, mh, nw, nh);

            free(mono);
            mono = big;
            mw = nw;
            mh = nh;
        }

        if (paper) {
            page_w = mm_to_px(paper->w_mm);
            page_h = mm_to_px(paper->h_mm);
        } else {
            page_w = (int)((double)hdr.PageSize[0] * ENGINE_DPI / 72.0 + 0.5);
            page_h = (int)((double)hdr.PageSize[1] * ENGINE_DPI / 72.0 + 0.5);
            if (page_w < mw)
                page_w = mw;
            if (page_h < mh)
                page_h = mh;
        }

        if (mw > page_w + 8 && mh <= page_h + 8) {
            unsigned char *rot = rotate_mono(mono, mw, mh);

            free(mono);
            mono = rot;
            {
                int t = mw;
                mw = mh;
                mh = t;
            }
            landscape = 1;
        } else if (opt_is(opts, "orientation-requested", "4")) {
            /* pdftopdf 已经把内容转进纵向页框，只需告诉设备按横向进纸 */
            landscape = 1;
        } else if (opt_is(opts, "orientation-requested", "5") ||
                   opt_is(opts, "orientation-requested", "6")) {
            dbg("orientation-requested=%s not supported by the engine; "
                "page may be rotated 180 degrees\n",
                opt_is(opts, "orientation-requested", "5") ? "5" : "6");
        }

        /* raster 比目标纸面还大（纸型选项与上游不一致）：等比缩小到能放下 */
        if (mw > page_w || mh > page_h) {
            double fx = (double)page_w / mw;
            double fy = (double)page_h / mh;
            double f = fx < fy ? fx : fy;
            int nw = (int)(mw * f);
            int nh = (int)(mh * f);
            unsigned char *small;

            if (nw < 1) nw = 1;
            if (nh < 1) nh = 1;
            dbg("page %lu: raster %dx%d too large for %dx%d, scaling to %dx%d\n",
                (unsigned long)npages + 1, mw, mh, page_w, page_h, nw, nh);
            small = scale_mono(mono, mw, mh, nw, nh);
            free(mono);
            mono = small;
            mw = nw;
            mh = nh;
        }

        page_bits = compose_page(mono, mw, mh, page_w, page_h, &dots);

        {
            if (estudio_jbig_encode(page_bits, (unsigned long)page_w,
                                    (unsigned long)page_h, &bie, &bie_len) != 0) {
                fprintf(stderr, "ERROR: JBIG encode failed on page %lu\n",
                        (unsigned long)npages + 1);
                return 1;
            }

            if (npages == pagecap) {
                size_t cap = pagecap ? pagecap * 2 : 16;
                struct page *np = realloc(pages, cap * sizeof(*np));

                if (!np) {
                    fprintf(stderr, "ERROR: out of memory (pages)\n");
                    return 1;
                }
                pages = np;
                pagecap = cap;
            }

            pages[npages].bie = bie;
            pages[npages].len = bie_len;
            pages[npages].dots = dots;
            pages[npages].width = page_w;
            pages[npages].height = page_h;
            pages[npages].landscape = landscape;
            pages[npages].pjl_paper = paper ? paper->pjl : NULL;
            npages++;

            dbg("page %lu: raster %dx%d -> %dx%d%s, jbig %lu bytes, dots %lu\n",
                (unsigned long)npages, mw, mh, page_w, page_h,
                landscape ? " (landscape)" : "", (unsigned long)bie_len, dots);
        }

        free(page_bits);
        free(mono);
    }

    cupsRasterClose(ras);
    if (in != stdin)
        fclose(in);

    if (npages == 0) {
        fprintf(stderr, "WARNING: no pages in job\n");
        return 0;
    }

    for (i = 0; i < (size_t)copies; i++) {
        size_t p;

        emit_job_header(username, i == 0, toner_save, smoothing);

        for (p = 0; p < npages; p++)
            emit_page(&pages[p], media_source, media_type);

        if (i + 1 < (size_t)copies)
            outs("@PJL COPYEND\r\n");   /* 下一份的 UEL 紧跟其后 */
        else
            outs("@PJL EOJ\r\n");
    }
    outs(UEL "\r\n");

    out_flush();

    for (i = 0; i < npages; i++)
        free(pages[i].bie);
    free(pages);

    dbg("job done: %lu page(s) x %d cop%s\n", (unsigned long)npages, copies,
        copies > 1 ? "ies" : "y");

    return 0;
}
