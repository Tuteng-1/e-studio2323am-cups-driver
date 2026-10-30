/*
 * prncheck.c — 校验 rastertoestudio 产出的 PJL + JBIG 打印流
 *
 *   ./prncheck file.prn [--pbm DIR]
 *
 * 对每一页做四件事：
 *   1. 把 IMAGELEN 分块拼回完整 BIE，检查 20 字节 BIH 字段是否符合实测值；
 *   2. 用 jbig 解码器解回位图，检查尺寸 == PAPERWIDTH x PAPERLENGTH；
 *   3. 数黑像素，与 @PJL SET DOTCOUNT 比对；
 *   4. 用 estudio_jbig_encode() 重新编码，要求与原数据逐字节一致。
 *
 * 第 4 步保证了 filter 的编码参数与实体 Windows 驱动完全相同。
 * 退出码：0 = 全部通过，1 = 有页失败，2 = 用法/IO 错误。
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "estudio_jbig.h"
#include "jbig.h"

#define BIH_LEN 20

struct page {
    unsigned char *data;
    size_t len;
    size_t cap;
};

static int append(struct page *p, const unsigned char *d, size_t n)
{
    if (p->len + n > p->cap) {
        size_t cap = p->cap ? p->cap : 65536;

        while (cap < p->len + n)
            cap *= 2;
        unsigned char *np = realloc(p->data, cap);

        if (!np)
            return -1;
        p->data = np;
        p->cap = cap;
    }
    memcpy(p->data + p->len, d, n);
    p->len += n;
    return 0;
}

static int find_marker(const unsigned char *buf, size_t size, size_t from,
                       const char *marker, size_t *at)
{
    size_t n = strlen(marker);
    size_t i;

    for (i = from; i + n <= size; i++) {
        if (buf[i] == (unsigned char)marker[0] && !memcmp(buf + i, marker, n)) {
            *at = i;
            return 1;
        }
    }
    return 0;
}

static long parse_number(const unsigned char *buf, size_t size, size_t at)
{
    size_t i = at;
    long v = 0;

    while (i < size && (buf[i] < '0' || buf[i] > '9'))
        i++;
    while (i < size && buf[i] >= '0' && buf[i] <= '9') {
        v = v * 10 + (buf[i] - '0');
        i++;
    }
    return v;
}

/* 找到本行结尾的 CRLF，返回二进制数据的起始偏移 */
static size_t after_line(const unsigned char *buf, size_t size, size_t at)
{
    while (at + 1 < size) {
        if (buf[at] == '\r' && buf[at + 1] == '\n')
            return at + 2;
        at++;
    }
    return size;
}

static unsigned long count_black(const unsigned char *bits, unsigned long w,
                                 unsigned long h, size_t stride)
{
    unsigned long total = 0, y;
    unsigned long x;

    for (y = 0; y < h; y++) {
        const unsigned char *row = bits + y * stride;

        for (x = 0; x < w; x++)
            total += (row[x >> 3] >> (7 - (x & 7))) & 1;
    }
    return total;
}

static int check_page(const struct page *p, int page_no, long declared_dots,
                      long paper_w, long paper_h, const char *pbm_dir)
{
    struct jbg_dec_state dec;
    unsigned long cnt = 0;
    int rc, ok = 1;
    unsigned long w, h;
    const unsigned char *img;
    size_t stride;
    unsigned long dots;
    unsigned char *re = NULL;
    size_t re_len = 0;
    unsigned long xd, yd, l0;
    int order, options;

    if (p->len < BIH_LEN) {
        fprintf(stderr, "page %d: image data only %lu bytes\n", page_no,
                (unsigned long)p->len);
        return 0;
    }

    xd = ((unsigned long)p->data[4] << 24) | ((unsigned long)p->data[5] << 16) |
         ((unsigned long)p->data[6] << 8) | p->data[7];
    yd = ((unsigned long)p->data[8] << 24) | ((unsigned long)p->data[9] << 16) |
         ((unsigned long)p->data[10] << 8) | p->data[11];
    l0 = ((unsigned long)p->data[12] << 24) | ((unsigned long)p->data[13] << 16) |
         ((unsigned long)p->data[14] << 8) | p->data[15];
    order = p->data[18];
    options = p->data[19];

    if (p->data[0] || p->data[1] || p->data[2] != 1 || p->data[3]) {
        fprintf(stderr, "page %d: BIH dl/dh/planes/byte3 = %02x %02x %02x %02x\n",
                page_no, p->data[0], p->data[1], p->data[2], p->data[3]);
        ok = 0;
    }
    if (l0 != ESTUDIO_JBIG_L0 || order != ESTUDIO_JBIG_ORDER ||
        options != ESTUDIO_JBIG_OPTIONS) {
        fprintf(stderr, "page %d: BIH L0=%lu order=%d options=0x%02x (want %d/%d/0x%02x)\n",
                page_no, l0, order, options, ESTUDIO_JBIG_L0, ESTUDIO_JBIG_ORDER,
                ESTUDIO_JBIG_OPTIONS);
        ok = 0;
    }
    if ((long)xd != paper_w || (long)yd != paper_h) {
        fprintf(stderr, "page %d: BIH %lux%lu != PAPER %ldx%ld\n", page_no, xd,
                yd, paper_w, paper_h);
        ok = 0;
    }

    jbg_dec_init(&dec);
    rc = jbg_dec_in(&dec, p->data, p->len, &cnt);
    if (rc != JBG_EOK) {
        fprintf(stderr, "page %d: JBIG decode failed (%d) after %lu bytes\n",
                page_no, rc, (unsigned long)cnt);
        jbg_dec_free(&dec);
        return 0;
    }

    w = jbg_dec_getwidth(&dec);
    h = jbg_dec_getheight(&dec);
    img = jbg_dec_getimage(&dec, 0);
    stride = (size_t)((w + 7) / 8);

    if ((long)w != paper_w || (long)h != paper_h) {
        fprintf(stderr, "page %d: decoded %lux%lu != PAPER %ldx%ld\n", page_no, w,
                h, paper_w, paper_h);
        ok = 0;
    }

    dots = count_black(img, w, h, stride);
    if ((long)dots != declared_dots) {
        fprintf(stderr, "page %d: DOTCOUNT %ld != actual %lu\n", page_no,
                declared_dots, dots);
        ok = 0;
    }

    if (estudio_jbig_encode(img, w, h, &re, &re_len) != 0) {
        fprintf(stderr, "page %d: re-encode failed\n", page_no);
        jbg_dec_free(&dec);
        return 0;
    }

    if (re_len != p->len || memcmp(re, p->data, re_len)) {
        size_t i = 0;

        while (i < re_len && i < p->len && re[i] == p->data[i])
            i++;
        fprintf(stderr,
                "page %d: re-encode mismatch at byte %lu (ours %lu bytes, device %lu)\n",
                page_no, (unsigned long)i, (unsigned long)re_len,
                (unsigned long)p->len);
        ok = 0;
    }

    if (pbm_dir && *pbm_dir) {
        char path[1024];
        FILE *f;

        snprintf(path, sizeof(path), "%s/page%02d.pbm", pbm_dir, page_no);
        f = fopen(path, "wb");
        if (f) {
            fprintf(f, "P4\n%lu %lu\n", w, h);
            fwrite(img, 1, stride * h, f);
            fclose(f);
        }
    }

    printf("page %d: %lux%lu, %lu bytes, %lu dots%s\n", page_no, w, h,
           (unsigned long)p->len, dots, ok ? "  OK" : "  FAIL");

    free(re);
    jbg_dec_free(&dec);
    return ok;
}

int main(int argc, char *argv[])
{
    FILE *f;
    const char *path = NULL, *pbm_dir = NULL;
    unsigned char *buf;
    long size;
    size_t pos = 0;
    long paper_w = 0, paper_h = 0;
    struct page page;
    int page_no = 0, failures = 0;
    long dots = -1;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--pbm") && i + 1 < argc)
            pbm_dir = argv[++i];
        else
            path = argv[i];
    }

    if (!path) {
        fprintf(stderr, "usage: %s file.prn [--pbm DIR]\n", argv[0]);
        return 2;
    }

    f = fopen(path, "rb");
    if (!f) {
        perror(path);
        return 2;
    }
    fseek(f, 0, SEEK_END);
    size = ftell(f);
    fseek(f, 0, SEEK_SET);
    buf = malloc((size_t)size + 1);
    if (!buf || fread(buf, 1, (size_t)size, f) != (size_t)size) {
        fprintf(stderr, "%s: read error\n", path);
        return 2;
    }
    fclose(f);

    memset(&page, 0, sizeof(page));

    for (;;) {
        size_t m_image = 0, m_dots = 0, m_paper = 0;
        int has_image, has_dots, has_paper;
        int is_image;

        has_image = find_marker(buf, (size_t)size, pos, "@PJL SET IMAGELEN=", &m_image);
        has_dots = find_marker(buf, (size_t)size, pos, "@PJL SET DOTCOUNT=", &m_dots);
        has_paper = find_marker(buf, (size_t)size, pos, "@PJL SET PAPERWIDTH=", &m_paper);

        if (!has_image && !has_dots)
            break;

        is_image = has_image && (!has_dots || m_image < m_dots);

        if (has_paper && m_paper < (is_image ? m_image : m_dots)) {
            size_t m_len;
            long v1, v2;

            v1 = parse_number(buf, (size_t)size, m_paper + strlen("@PJL SET PAPERWIDTH="));
            if (find_marker(buf, (size_t)size, m_paper, "@PJL SET PAPERLENGTH=", &m_len))
                v2 = parse_number(buf, (size_t)size, m_len + strlen("@PJL SET PAPERLENGTH="));
            else
                v2 = 0;

            paper_w = v1;
            paper_h = v2;
        }

        if (is_image) {
            long n = parse_number(buf, (size_t)size, m_image + strlen("@PJL SET IMAGELEN="));
            size_t start = after_line(buf, (size_t)size, m_image);

            if (n < 0 || start + (size_t)n > (size_t)size) {
                fprintf(stderr, "IMAGELEN=%ld out of range\n", n);
                return 2;
            }
            if (append(&page, buf + start, (size_t)n) != 0) {
                fprintf(stderr, "out of memory\n");
                return 2;
            }
            pos = start + (size_t)n;
        } else {
            dots = parse_number(buf, (size_t)size, m_dots + strlen("@PJL SET DOTCOUNT="));
            page_no++;
            if (!check_page(&page, page_no, dots, paper_w, paper_h, pbm_dir))
                failures++;
            page.len = 0;
            pos = m_dots + strlen("@PJL SET DOTCOUNT=");
        }
    }

    if (page_no == 0) {
        fprintf(stderr, "%s: no pages found\n", path);
        return 2;
    }

    printf("%s: %d page(s), %d failure(s)\n", path, page_no, failures);
    free(page.data);
    free(buf);
    return failures ? 1 : 0;
}
