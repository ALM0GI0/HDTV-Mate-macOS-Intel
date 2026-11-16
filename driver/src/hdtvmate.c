// SPDX-License-Identifier: GPL-2.0-only
/*
 * hdtvmate - native macOS (libusb) driver/tool for the Zenview / GTMEDIA
 * HDTV Mate ATSC 1.0 / 3.0 USB tuner (23e2:2b02).
 *
 *   ITE IT930x USB bridge  -> ported from koreapyj/cxd28xx it930x.c
 *   Sony CXD2878 demod + Ascot3 tuner -> cxd2878.c compiled unmodified
 *                                        against a tiny kernel shim
 *   ATSC 3.0 ALP-div-TS -> ALP -> IPv4 (cxd28xx alp.c parser)
 *
 * No kernel extension, no VM. GPL-2.0-only (derived from cxd28xx).
 */
#include "kshim.h"
#include "cxd2878.h"
#include "cxd2878_priv.h"
#include "alp_user.h"

#include <libusb.h>
#include <signal.h>
#include <getopt.h>
#include <sys/time.h>
#include <zlib.h>
#include <stdarg.h>

int kshim_verbose, kshim_quiet;

void kshim_log(int level, const char *fmt, ...)
{
	static const char *pfx[] = { "ERR: ", "warn: ", "", "dbg: " };
	char buf[512];
	va_list ap;
	if (level == 3 && !kshim_verbose) return;
	if (level == 2 && kshim_quiet && !kshim_verbose) return;
	va_start(ap, fmt);
	vsnprintf(buf, sizeof(buf), fmt, ap);
	va_end(ap);
	size_t n = strlen(buf);
	while (n && (buf[n - 1] == '\n' || buf[n - 1] == ' ')) buf[--n] = 0;
	char *b = buf;
	while (*b == ' ') b++;
	if (!strncmp(b, "cxd2878: ", 9)) b += 9;
	fprintf(stderr, "[demod] %s%s\n", pfx[level], b);
}

/* ======================= IT930x bridge ======================= */

#define VID 0x23e2
#define PID 0x2b02

#define IT930X_CMD_REG_READ          0x0000
#define IT930X_CMD_REG_WRITE         0x0001
#define IT930X_CMD_QUERYINFO         0x0022
#define IT930X_CMD_BOOT              0x0023
#define IT930X_CMD_FW_SCATTER_WRITE  0x0029
#define IT930X_CMD_GENERIC_I2C_RD    0x002a
#define IT930X_CMD_GENERIC_I2C_WR    0x002b

#define EP_CMD_OUT 0x02
#define EP_CMD_IN  0x81
#define EP_TS      0x84

#define CMD_MAX_PKT     512
#define CMD_MAX_PAYLOAD 250
#define USB_TIMEOUT_MS  1000
#define I2C_SHORT_MAX   40
#define I2C_STAGE_CHUNK 40

#define URB_COUNT    8
#define URB_BUF_SIZE (188 * 348)

#define REG_CLK_DISABLE    0x4976
#define REG_PLL_RESET      0x4bfb
#define REG_TS_CLK_CFG     0x4978
#define REG_EXT_CLK_RESET  0x4977
#define REG_I2C_BUS0_SPEED 0xf6a7
#define REG_I2C_BUS1_SPEED 0xf103
#define REG_I2C_TRIG       0x4900
#define REG_I2C_READ_BUF   0xf000
#define REG_I2C_WRITE_BUF  0xf001
#define REG_I2C_BUS_CTRL   0xf424
#define REG_TS_FAIL_IGNORE 0xda5a
#define REG_TS_SYNC_BYPASS 0xda1a
#define REG_TS_OUT_EN      0xd833
#define REG_TS_OUT_CFG0    0xd830
#define REG_TS_OUT_CFG1    0xd831
#define REG_TS_OUT_CFG2    0xd832

/* HDTV Mate board config (from cxd28xx it930x_id_table) */
#define BOARD_I2C_BUS     3
#define BOARD_DEMOD_ADDR  0x6c
#define BOARD_TUNER_ADDR  0x60
#define BOARD_GPIO_RESET  2
#define BOARD_GPIO_HI     14
#define BOARD_I2C_NOTIFY  0x38

static const struct { u32 en, on, val; } gpio_regs[16] = {
	{ 0xd8b0, 0xd8b1, 0xd8af }, { 0xd8b8, 0xd8b9, 0xd8b7 },
	{ 0xd8b4, 0xd8b5, 0xd8b3 }, { 0xd8c0, 0xd8c1, 0xd8bf },
	{ 0xd8bc, 0xd8bd, 0xd8bb }, { 0xd8c8, 0xd8c9, 0xd8c7 },
	{ 0xd8c4, 0xd8c5, 0xd8c3 }, { 0xd8d0, 0xd8d1, 0xd8cf },
	{ 0xd8cc, 0xd8cd, 0xd8cb }, { 0xd8d8, 0xd8d9, 0xd8d7 },
	{ 0xd8d4, 0xd8d5, 0xd8d3 }, { 0xd8e0, 0xd8e1, 0xd8df },
	{ 0xd8dc, 0xd8dd, 0xd8db }, { 0xd8e4, 0xd8e5, 0xd8e3 },
	{ 0xd8e8, 0xd8e9, 0xd8e7 }, { 0xd8ec, 0xd8ed, 0xd8eb },
};

struct bridge {
	libusb_context *ctx;
	libusb_device_handle *h;
	pthread_mutex_t cmd_lock;
	u8 seq;
	u32 fw_version;
};

static struct bridge B;

static u16 it_csum(const u8 *buf, size_t len)
{
	u32 sum = 0;
	size_t i;
	for (i = 0; i + 1 < len; i += 2)
		sum += ((u16)buf[i] << 8) | buf[i + 1];
	if (len & 1)
		sum += (u16)buf[len - 1] << 8;
	return (u16)~sum;
}

static int it_cmd(u16 cmd, const u8 *tx_payload, u8 tx_len,
		  u8 *rx_payload, u8 rx_plen)
{
	u8 tx[CMD_MAX_PKT], rx[CMD_MAX_PKT];
	int tlen, actual = 0, rlen = 0, r, ret = 0;
	u16 c;

	if (tx_len > CMD_MAX_PAYLOAD || rx_plen > CMD_MAX_PAYLOAD)
		return -E2BIG;

	pthread_mutex_lock(&B.cmd_lock);
	tlen = 4 + tx_len + 2;
	tx[1] = cmd >> 8;
	tx[2] = cmd & 0xff;
	tx[3] = B.seq++;
	if (tx_len)
		memcpy(&tx[4], tx_payload, tx_len);
	c = it_csum(&tx[1], 3 + tx_len);
	tx[4 + tx_len] = c >> 8;
	tx[5 + tx_len] = c & 0xff;
	tx[0] = tlen - 1;

	r = libusb_bulk_transfer(B.h, EP_CMD_OUT, tx, tlen, &actual, USB_TIMEOUT_MS);
	if (r) { ret = -EIO; goto out; }
	r = libusb_bulk_transfer(B.h, EP_CMD_IN, rx, CMD_MAX_PKT, &rlen, USB_TIMEOUT_MS);
	if (r) { ret = -EIO; goto out; }
	if (rlen < 5) { ret = -EPROTO; goto out; }
	if (it_csum(&rx[1], rlen - 3) != (((u16)rx[rlen - 2] << 8) | rx[rlen - 1])) {
		ret = -EPROTO; goto out;
	}
	if (rx[2]) {
		if (kshim_verbose)
			fprintf(stderr, "[bridge] cmd 0x%04x status %u\n", cmd, rx[2]);
		ret = -EIO; goto out;
	}
	if (rx_plen && rx_payload) {
		if (rlen - 5 < rx_plen) { ret = -EPROTO; goto out; }
		memcpy(rx_payload, &rx[3], rx_plen);
	}
out:
	pthread_mutex_unlock(&B.cmd_lock);
	return ret;
}

static int it_wr_regs(u32 reg, const u8 *buf, u8 len)
{
	u8 p[6 + 250];
	p[0] = len; p[1] = 2;
	p[2] = reg >> 24; p[3] = reg >> 16; p[4] = reg >> 8; p[5] = reg;
	if (len) memcpy(&p[6], buf, len);
	return it_cmd(IT930X_CMD_REG_WRITE, p, 6 + len, NULL, 0);
}

static int it_rd_regs(u32 reg, u8 *buf, u8 len)
{
	u8 p[6] = { len, 2, reg >> 24, reg >> 16, reg >> 8, reg };
	return it_cmd(IT930X_CMD_REG_READ, p, 6, buf, len);
}

static int it_wr(u32 reg, u8 v) { return it_wr_regs(reg, &v, 1); }
static int it_rd(u32 reg, u8 *v) { return it_rd_regs(reg, v, 1); }

static int it_patch(u32 reg, u8 val, u8 mask)
{
	u8 cur; int r = it_rd(reg, &cur);
	if (r) return r;
	u8 nxt = (cur & ~mask) | (val & mask);
	return nxt == cur ? 0 : it_wr(reg, nxt);
}

#define CK(x) do { int _r = (x); if (_r) { fprintf(stderr, "[bridge] %s failed (%d) at line %d\n", #x, _r, __LINE__); return _r; } } while (0)

static int gpio_set(u8 g, bool v)
{
	CK(it_wr(gpio_regs[g - 1].en, 1));
	CK(it_wr(gpio_regs[g - 1].on, 1));
	return it_wr(gpio_regs[g - 1].val, v ? 1 : 0);
}

static int gpio_pulse(u8 g)
{
	CK(it_wr(gpio_regs[g - 1].val, 1));
	CK(it_wr(gpio_regs[g - 1].en, 1));
	CK(it_wr(gpio_regs[g - 1].on, 1));
	CK(it_wr(gpio_regs[g - 1].val, 0));
	return it_wr(gpio_regs[g - 1].val, 1);
}

/* ---- I2C relay ---- */
static int i2c_gen_wr(u8 bus, u8 slave, const u8 *buf, u8 len)
{
	u8 p[3 + I2C_SHORT_MAX];
	p[0] = len; p[1] = bus; p[2] = slave;
	memcpy(&p[3], buf, len);
	return it_cmd(IT930X_CMD_GENERIC_I2C_WR, p, 3 + len, NULL, 0);
}

static int i2c_gen_rd(u8 bus, u8 slave, u8 *buf, u8 len)
{
	u8 p[3] = { len, bus, slave };
	return it_cmd(IT930X_CMD_GENERIC_I2C_RD, p, 3, buf, len);
}

static int it_i2c_write(u8 bus, u8 slave, const u8 *buf, u16 len)
{
	u32 off = 0, rem = len;
	if (!len) return 0;
	if (len <= I2C_SHORT_MAX) return i2c_gen_wr(bus, slave, buf, len);
	if (len > 255) return -E2BIG;
	while (rem) {
		u8 chunk = rem > I2C_STAGE_CHUNK ? I2C_STAGE_CHUNK : rem;
		CK(it_wr_regs(REG_I2C_WRITE_BUF + off, &buf[off], chunk));
		off += chunk; rem -= chunk;
	}
	u8 trig[4] = { 0xf4, bus, slave, (u8)len };
	return it_wr_regs(REG_I2C_TRIG, trig, 4);
}

static int it_i2c_read(u8 bus, u8 slave, u8 *buf, u16 len)
{
	if (!len) return 0;
	if (len <= I2C_SHORT_MAX) return i2c_gen_rd(bus, slave, buf, len);
	if (len > 255) return -E2BIG;
	u8 trig[4] = { 0xf5, bus, slave, (u8)len };
	CK(it_wr_regs(REG_I2C_TRIG, trig, 4));
	return it_rd_regs(REG_I2C_READ_BUF, buf, len);
}

static pthread_mutex_t io_lock = PTHREAD_MUTEX_INITIALIZER;

static int it_i2c_xfer(struct i2c_adapter *adap, struct i2c_msg *m, int num)
{
	u8 bus = BOARD_I2C_BUS;
	int i, ret = 0;
	(void)adap;

	pthread_mutex_lock(&io_lock);
	if (num == 2 && !(m[0].flags & I2C_M_RD) && (m[1].flags & I2C_M_RD) &&
	    m[0].len <= 255 && m[1].len <= 255) {
		/* repeated start via F424 bus hold */
		ret = it_wr(REG_I2C_BUS_CTRL, 1);
		if (!ret) ret = it_i2c_write(bus, m[0].addr << 1, m[0].buf, m[0].len);
		if (ret) { it_wr(REG_I2C_BUS_CTRL, 0); goto out; }
		ret = it_wr(REG_I2C_BUS_CTRL, 0);
		if (!ret) ret = it_i2c_read(bus, m[1].addr << 1, m[1].buf, m[1].len);
		goto out;
	}
	for (i = 0; i < num && !ret; i++) {
		if (m[i].flags & I2C_M_RD)
			ret = it_i2c_read(bus, m[i].addr << 1, m[i].buf, m[i].len);
		else
			ret = it_i2c_write(bus, m[i].addr << 1, m[i].buf, m[i].len);
	}
out:
	pthread_mutex_unlock(&io_lock);
	if (ret && kshim_verbose)
		fprintf(stderr, "[i2c] xfer addr=0x%02x failed %d\n", m[0].addr << 1, ret);
	return ret ? ret : num;
}

/* ---- firmware ---- */
static int it_fw_version(u32 *ver)
{
	u8 tx = 1, rx[4];
	int r = it_cmd(IT930X_CMD_QUERYINFO, &tx, 1, rx, 4);
	if (!r) *ver = ((u32)rx[0] << 24) | ((u32)rx[1] << 16) | ((u32)rx[2] << 8) | rx[3];
	return r;
}

static int it_load_fw(const char *path)
{
	FILE *f = fopen(path, "rb");
	if (!f) {
		fprintf(stderr, "[bridge] cannot open firmware '%s': %s\n", path, strerror(errno));
		return -ENOENT;
	}
	fseek(f, 0, SEEK_END);
	long sz = ftell(f);
	fseek(f, 0, SEEK_SET);
	u8 *fw = malloc(sz);
	if (fread(fw, 1, sz, f) != (size_t)sz) { fclose(f); free(fw); return -EIO; }
	fclose(f);
	fprintf(stderr, "[bridge] loading firmware %s (%ld bytes)\n", path, sz);

	size_t i = 0;
	int ret = 0, blocks = 0;
	while (i < (size_t)sz) {
		const u8 *p = &fw[i];
		size_t blen = 0, plen;
		unsigned j;
		if (i + 7 > (size_t)sz || p[0] != 0x03) {
			fprintf(stderr, "[bridge] bad firmware block at %zu (marker 0x%02x)\n", i, p[0]);
			ret = -EINVAL; goto out;
		}
		u8 seg = p[3];
		plen = 4 + (size_t)seg * 3;
		for (j = 0; j < seg; j++) blen += p[6 + j * 3];
		if (!blen) { i += plen; continue; }
		plen += blen;
		if (i + plen > (size_t)sz || plen > CMD_MAX_PAYLOAD) {
			fprintf(stderr, "[bridge] bad firmware block length at %zu\n", i);
			ret = -EINVAL; goto out;
		}
		ret = it_cmd(IT930X_CMD_FW_SCATTER_WRITE, p, (u8)plen, NULL, 0);
		if (ret) { fprintf(stderr, "[bridge] fw write failed at %zu (%d)\n", i, ret); goto out; }
		i += plen;
		blocks++;
	}
	ret = it_cmd(IT930X_CMD_BOOT, NULL, 0, NULL, 0);
	if (ret) fprintf(stderr, "[bridge] firmware boot failed (%d)\n", ret);
	else fprintf(stderr, "[bridge] %d blocks written, booted\n", blocks);
out:
	free(fw);
	return ret;
}

/* ---- init stages ---- */
static int stage_pre_init(void)
{
	CK(it_wr(0xda05, 0x01));
	CK(gpio_pulse(BOARD_GPIO_RESET));
	CK(gpio_set(BOARD_GPIO_HI, true));
	CK(it_wr(REG_CLK_DISABLE, 0x00));
	CK(it_wr(REG_PLL_RESET, 0x00));
	CK(it_wr(REG_TS_CLK_CFG, 0x00));
	CK(it_wr(REG_EXT_CLK_RESET, 0x00));
	CK(it_wr(REG_I2C_BUS0_SPEED, 0x07));
	CK(it_wr(REG_I2C_BUS1_SPEED, 0x07));
	return it_wr(REG_TS_SYNC_BYPASS, 0x00);
}

static int stage_fw_ready(const char *fwpath)
{
	u32 v = 0;
	if (!it_fw_version(&v) && v) {
		fprintf(stderr, "[bridge] firmware already running: %u.%u.%u.%u\n",
			v >> 24, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff);
		B.fw_version = v;
		return 0;
	}
	fprintf(stderr, "[bridge] cold boot\n");
	CK(it_load_fw(fwpath));
	CK(it_fw_version(&v));
	if (!v) { fprintf(stderr, "[bridge] firmware did not start\n"); return -ENODEV; }
	fprintf(stderr, "[bridge] firmware version: %u.%u.%u.%u\n",
		v >> 24, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff);
	B.fw_version = v;
	return 0;
}

static int stage_post_boot(void)
{
	u8 dd88[2] = { (URB_BUF_SIZE / 4) & 0xff, ((URB_BUF_SIZE / 4) >> 8) & 0xff };
	u8 v;
	CK(it_wr(REG_I2C_BUS0_SPEED, 0x07));
	CK(it_wr(REG_I2C_BUS1_SPEED, 0x07));
	CK(it_wr(REG_TS_SYNC_BYPASS, 0x00));
	CK(it_patch(0xf41f, 0x04, 0x04));
	CK(it_wr(0xda10, 0x00));
	CK(it_wr(0xf41a, 0x01));
	CK(it_wr(0xda1d, 0x01));
	CK(it_rd(0xdd11, &v));
	CK(it_wr(0xdd11, v & ~0x20));
	CK(it_wr(0xdd13, 0x00));
	CK(it_rd(0xdd11, &v));
	CK(it_wr(0xdd11, v | 0x20));
	CK(it_wr_regs(0xdd88, dd88, 2));
	CK(it_wr(0xdd0c, 0x80));
	CK(it_wr(0xda05, 0x00));
	CK(it_wr(0xda06, 0x00));
	CK(it_wr(0xda1d, 0x00));
	CK(it_wr(0xd920, 0x00));
	CK(it_wr(REG_TS_OUT_EN, 0x01));
	CK(it_wr(REG_TS_OUT_CFG0, 0x00));
	CK(it_wr(REG_TS_OUT_CFG1, 0x01));
	CK(it_wr(REG_TS_OUT_CFG2, 0x00));
	CK(it_wr(REG_CLK_DISABLE, 0x01));
	CK(it_wr(0x4975, BOARD_I2C_NOTIFY));   /* frontend 0 i2c addr notify */
	CK(it_wr(0x4971, BOARD_I2C_BUS));      /* frontend 0 bus */
	CK(gpio_set(11, true));
	CK(gpio_pulse(BOARD_GPIO_RESET));
	return it_wr(REG_TS_FAIL_IGNORE, 0x1f);
}

static int stage_ts_port_cfg(void)
{
	CK(it_wr(REG_TS_SYNC_BYPASS, 0x00));
	CK(it_wr(0xda34, 0x00));
	CK(it_wr(0xda51, 0xbc));
	CK(it_wr(0xda5f, 0x00));
	CK(it_wr(0xda60, 0x00));
	CK(it_wr(0xda61, 0x00));
	CK(it_wr(0xda62, 0x00));
	CK(it_wr(0xda58, 0x00));   /* port 0 serial */
	CK(it_wr(0xda73, 0x01));
	CK(it_wr(0xda78, 0x47));
	CK(it_wr(0xda4c, 0x01));   /* enable port 0 */
	return it_wr(REG_TS_FAIL_IGNORE, 0x1f);
}

static int bridge_open(void)
{
	int r = libusb_init(&B.ctx);
	if (r) { fprintf(stderr, "libusb_init: %s\n", libusb_error_name(r)); return -1; }
	B.h = libusb_open_device_with_vid_pid(B.ctx, VID, PID);
	if (!B.h) {
		fprintf(stderr, "ERROR: HDTV Mate (23e2:2b02) not found. Is the stick plugged in?\n");
		return -1;
	}
	libusb_set_auto_detach_kernel_driver(B.h, 1);
	r = libusb_claim_interface(B.h, 0);
	if (r) { fprintf(stderr, "claim interface: %s\n", libusb_error_name(r)); return -1; }
	pthread_mutex_init(&B.cmd_lock, NULL);
	return 0;
}

static int bridge_init(const char *fwpath)
{
	pthread_mutex_lock(&io_lock);
	int r = stage_pre_init();
	if (!r) r = stage_fw_ready(fwpath);
	if (!r) r = stage_post_boot();
	pthread_mutex_unlock(&io_lock);
	if (!r) fprintf(stderr, "[bridge] initialization complete\n");
	return r;
}

/* ======================= output: pcap / LLS ======================= */

static volatile sig_atomic_t g_stop;
static FILE *g_ts_out, *g_pcap;
static struct alp_dev *g_alp;
static struct dvb_frontend *g_fe;
static u64 g_ts_bytes, g_ts_pkts, g_ts_sync_miss, g_usb_err, g_ts_tei, g_ts_cc_err;
static u8 g_cc[8192];

struct flow { u32 dst; u16 port; u64 pkts, bytes; };
#define MAX_FLOWS 64
static struct flow g_flows[MAX_FLOWS];
static int g_nflows;
static int g_slt_version = -1;
static pthread_mutex_t out_lock = PTHREAD_MUTEX_INITIALIZER;

static void pcap_header(FILE *f)
{
	struct { u32 magic; u16 vmaj, vmin; s32 tz; u32 sig, snap, link; } h =
		{ 0xa1b2c3d4, 2, 4, 0, 0, 65535, 101 /* LINKTYPE_RAW */ };
	fwrite(&h, sizeof(h), 1, f);
}

static char *xml_attr(const char *el, const char *end, const char *name, char *out, size_t n)
{
	char pat[64];
	snprintf(pat, sizeof(pat), " %s=\"", name);
	const char *p = strstr(el, pat);
	out[0] = 0;
	if (!p || p > end) return out;
	p += strlen(pat);
	const char *q = strchr(p, '"');
	if (!q) return out;
	size_t l = (size_t)(q - p) < n - 1 ? (size_t)(q - p) : n - 1;
	memcpy(out, p, l);
	out[l] = 0;
	return out;
}

static void print_slt(const char *xml)
{
	char bsid[16];
	const char *slt = strstr(xml, "<SLT");
	if (slt) xml_attr(slt, slt + 200, "bsid", bsid, sizeof(bsid));
	fprintf(stderr, "\n=== ATSC 3.0 Service List (SLT) bsid=%s ===\n", slt ? bsid : "?");
	const char *p = xml;
	while ((p = strstr(p, "<Service ")) != NULL) {
		const char *end = strstr(p, "</Service>");
		const char *tagend = strchr(p, '>');
		if (!end) end = tagend;
		char name[64], maj[8], min_[8], cat[4], prot[8], sls[24], slsport[8], prot_sls[4], drm[8];
		xml_attr(p, tagend, "shortServiceName", name, sizeof(name));
		xml_attr(p, tagend, "majorChannelNo", maj, sizeof(maj));
		xml_attr(p, tagend, "minorChannelNo", min_, sizeof(min_));
		xml_attr(p, tagend, "serviceCategory", cat, sizeof(cat));
		xml_attr(p, tagend, "sltSvcSeqNum", prot, sizeof(prot));
		xml_attr(p, tagend, "protected", drm, sizeof(drm));
		const char *bss = strstr(p, "<BroadcastSvcSignaling");
		sls[0] = slsport[0] = prot_sls[0] = 0;
		if (bss && bss < end) {
			const char *be = strchr(bss, '>');
			xml_attr(bss, be, "slsDestinationIpAddress", sls, sizeof(sls));
			xml_attr(bss, be, "slsDestinationUdpPort", slsport, sizeof(slsport));
			xml_attr(bss, be, "slsProtocol", prot_sls, sizeof(prot_sls));
		}
		const char *cats[] = { "?", "Linear A/V", "Linear audio", "App-based", "ESG", "EAS", "?" };
		int ci = atoi(cat);
		fprintf(stderr, "  %3s.%-3s %-12s %-13s SLS %s:%s (%s)%s\n", maj, min_, name,
			cats[ci >= 0 && ci <= 5 ? ci : 6], sls, slsport,
			atoi(prot_sls) == 1 ? "ROUTE" : atoi(prot_sls) == 2 ? "MMTP" : prot_sls,
			!strcmp(drm, "true") ? "  [DRM]" : "");
		p = end ? end : p + 9;
	}
	fprintf(stderr, "\n");
}

static void lls_gunzip_slt(const u8 *gz, u32 len, int version)
{
	if (version == g_slt_version) return;
	static u8 xml[65536];
	z_stream z = { 0 };
	z.next_in = (Bytef *)gz;
	z.avail_in = len;
	z.next_out = xml;
	z.avail_out = sizeof(xml) - 1;
	if (inflateInit2(&z, 16 + MAX_WBITS) != Z_OK) return;
	int r = inflate(&z, Z_FINISH);
	inflateEnd(&z);
	if (r != Z_STREAM_END) return;
	xml[z.total_out] = 0;
	g_slt_version = version;
	if (kshim_verbose) fprintf(stderr, "%s\n", xml);
	print_slt((char *)xml);
}

static void handle_lls(const u8 *p, u32 len)
{
	if (len < 5) return;
	u8 table_id = p[0];
	if (table_id == 0x01) {                 /* plain SLT */
		lls_gunzip_slt(p + 4, len - 4, p[3]);
	} else if (table_id == 0xFE) {          /* SignedMultiTable (A/331) */
		const u8 *b = p + 4, *end = p + len;
		if (b >= end) return;
		u8 n = *b++;
		for (u8 i = 0; i < n && b + 4 <= end; i++) {
			u8 pid = b[0], pver = b[1];
			u16 plen = (b[2] << 8) | b[3];
			b += 4;
			if (b + plen > end) return;
			if (pid == 0x01) lls_gunzip_slt(b, plen, pver);
			b += plen;
		}
	}
}

static void pcap_write(const u8 *ip, u32 len);
static void on_ip(void *priv, const u8 *ip, u32 len)
{
	(void)priv;
	if (g_pcap) pcap_write(ip, len);
	if ((ip[0] >> 4) != 4) return;
	u32 ihl = (ip[0] & 0xf) * 4;
	u32 dst = ((u32)ip[16] << 24) | ((u32)ip[17] << 16) | ((u32)ip[18] << 8) | ip[19];
	u16 dport = 0;
	if (ip[9] == 17 && len >= ihl + 8)
		dport = (ip[ihl + 2] << 8) | ip[ihl + 3];

	int i;
	for (i = 0; i < g_nflows; i++)
		if (g_flows[i].dst == dst && g_flows[i].port == dport) break;
	if (i == g_nflows && g_nflows < MAX_FLOWS)
		g_flows[g_nflows++] = (struct flow){ dst, dport, 0, 0 };
	if (i < MAX_FLOWS) { g_flows[i].pkts++; g_flows[i].bytes += len; }

	if (dst == 0xE000173C /* 224.0.23.60 */ && dport == 4937 && len > ihl + 8)
		handle_lls(ip + ihl + 8, len - ihl - 8);
}

/* ======================= TS streaming ======================= */

static struct libusb_transfer *g_xfers[URB_COUNT];

/* Output rings: USB callbacks never block on a slow consumer (ffplay probing, a pipe). */
#define RING_SIZE (64u << 20)
struct ring {
	FILE *out;
	u8 *buf;
	size_t head, tail;
	u64 drop;
	pthread_mutex_t lock;
	pthread_cond_t cond;
	pthread_t thr;
	volatile int stop, dead;
};
static struct ring g_ts_ring, g_pcap_ring;
static int g_atsc3;

static void ring_put(struct ring *r, const u8 *d, size_t n)
{
	if (!r->buf || r->dead) return;
	pthread_mutex_lock(&r->lock);
	if (r->head - r->tail + n > RING_SIZE) { r->drop += n; pthread_mutex_unlock(&r->lock); return; }
	for (size_t i = 0; i < n; ) {
		size_t off = (r->head + i) % RING_SIZE, chunk = RING_SIZE - off;
		if (chunk > n - i) chunk = n - i;
		memcpy(r->buf + off, d + i, chunk);
		i += chunk;
	}
	r->head += n;
	pthread_cond_signal(&r->cond);
	pthread_mutex_unlock(&r->lock);
}

static void *ring_thread(void *arg)
{
	struct ring *r = arg;
	for (;;) {
		pthread_mutex_lock(&r->lock);
		while (r->head == r->tail && !r->stop) pthread_cond_wait(&r->cond, &r->lock);
		if (r->head == r->tail && r->stop) { pthread_mutex_unlock(&r->lock); break; }
		size_t off = r->tail % RING_SIZE, n = r->head - r->tail;
		if (n > RING_SIZE - off) n = RING_SIZE - off;
		pthread_mutex_unlock(&r->lock);
		size_t w = fwrite(r->buf + off, 1, n, r->out);
		if (r->out == stdout) fflush(r->out);
		pthread_mutex_lock(&r->lock);
		r->tail += n;
		pthread_mutex_unlock(&r->lock);
		if (w != n) { r->dead = 1; break; }   /* consumer went away */
	}
	fflush(r->out);
	return NULL;
}

static void ring_start(struct ring *r, FILE *out)
{
	r->out = out;
	r->buf = malloc(RING_SIZE);
	pthread_mutex_init(&r->lock, NULL);
	pthread_cond_init(&r->cond, NULL);
	pthread_create(&r->thr, NULL, ring_thread, r);
}

static void ring_finish(struct ring *r, const char *name)
{
	if (!r->buf) return;
	pthread_mutex_lock(&r->lock);
	r->stop = 1;
	pthread_cond_signal(&r->cond);
	pthread_mutex_unlock(&r->lock);
	pthread_join(r->thr, NULL);
	if (r->drop) fprintf(stderr, "%s output overflow: %llu bytes dropped\n", name, (unsigned long long)r->drop);
}

static void pcap_write(const u8 *ip, u32 len)
{
	struct timeval tv;
	gettimeofday(&tv, NULL);
	u32 rec[4] = { (u32)tv.tv_sec, (u32)tv.tv_usec, len, len };
	u8 tmp[16 + 65536];
	memcpy(tmp, rec, 16);
	memcpy(tmp + 16, ip, len);
	ring_put(&g_pcap_ring, tmp, 16 + len);
}

static void LIBUSB_CALL ts_cb(struct libusb_transfer *t)
{
	if (t->status == LIBUSB_TRANSFER_COMPLETED && t->actual_length > 0) {
		u32 len = t->actual_length, pos;
		pthread_mutex_lock(&out_lock);
		g_ts_bytes += len;
		for (pos = 0; pos + 188 <= len; pos += 188) {
			const u8 *p = t->buffer + pos;
			if (p[0] != 0x47) { g_ts_sync_miss++; continue; }
			g_ts_pkts++;
			if (g_atsc3) continue;
			if (p[1] & 0x80) { g_ts_tei++; continue; }
			u16 pid = ((p[1] & 0x1f) << 8) | p[2];
			if (pid == 0x1fff || !(p[3] & 0x10)) continue;   /* null / no payload */
			u8 cc = p[3] & 0x0f, prev = g_cc[pid];
			if (prev & 0x80) {
				u8 exp = ((prev & 0x0f) + 1) & 0x0f;
				if (cc != exp && cc != (prev & 0x0f)) g_ts_cc_err++;  /* dup allowed */
			}
			g_cc[pid] = 0x80 | cc;
		}
		if (g_ts_out) ring_put(&g_ts_ring, t->buffer, len);
		if (g_atsc3 && g_alp)
			cxd2878_alp_feed_raw(g_fe->demodulator_priv, g_alp, t->buffer, len);
		pthread_mutex_unlock(&out_lock);
	} else if (t->status == LIBUSB_TRANSFER_CANCELLED || t->status == LIBUSB_TRANSFER_NO_DEVICE) {
		if (t->status == LIBUSB_TRANSFER_NO_DEVICE) g_usb_err++;
		t->user_data = NULL;
		return;
	} else if (t->status != LIBUSB_TRANSFER_COMPLETED &&
		   t->status != LIBUSB_TRANSFER_TIMED_OUT) {
		g_usb_err++;
	}
	if (!g_stop) {
		if (libusb_submit_transfer(t)) { g_usb_err++; t->user_data = NULL; }
	} else {
		t->user_data = NULL;
	}
}

static void *event_thread(void *arg)
{
	(void)arg;
	struct timeval tv = { 0, 100000 };
	for (;;) {
		libusb_handle_events_timeout(B.ctx, &tv);
		if (g_stop) {
			int busy = 0;
			for (int i = 0; i < URB_COUNT; i++) if (g_xfers[i] && g_xfers[i]->user_data) busy = 1;
			if (!busy) break;
		}
	}
	return NULL;
}

static pthread_t g_evt;

static int streaming_start(void)
{
	pthread_mutex_lock(&io_lock);
	int r = stage_ts_port_cfg();
	pthread_mutex_unlock(&io_lock);
	if (r) return r;

	/* flush stale FIFO */
	static u8 flush[URB_BUF_SIZE];
	int n = 0;
	libusb_bulk_transfer(B.h, EP_TS, flush, sizeof(flush), &n, 100);

	for (int i = 0; i < URB_COUNT; i++) {
		g_xfers[i] = libusb_alloc_transfer(0);
		u8 *buf = malloc(URB_BUF_SIZE);
		libusb_fill_bulk_transfer(g_xfers[i], B.h, EP_TS, buf, URB_BUF_SIZE, ts_cb, (void *)1, 0);
		r = libusb_submit_transfer(g_xfers[i]);
		if (r) { fprintf(stderr, "submit transfer: %s\n", libusb_error_name(r)); return -EIO; }
	}
	pthread_create(&g_evt, NULL, event_thread, NULL);
	fprintf(stderr, "[ts] streaming started\n");
	return 0;
}

static void streaming_stop(void)
{
	for (int i = 0; i < URB_COUNT; i++)
		if (g_xfers[i] && g_xfers[i]->user_data) libusb_cancel_transfer(g_xfers[i]);
	pthread_join(g_evt, NULL);
}

/* ======================= frontend ======================= */

static struct cxd2878_config g_cfg;
static struct i2c_adapter g_i2c = { .dev = { "it930x-i2c-3" }, .xfer = it_i2c_xfer, .name = "it930x-i2c-3" };
static struct net_device g_alp_netdev;

static struct dvb_frontend *frontend_attach(void)
{
	memset(&g_cfg, 0, sizeof(g_cfg));
	g_cfg.addr_slvt = BOARD_DEMOD_ADDR;
	g_cfg.xtal = SONY_DEMOD_XTAL_24000KHz;
	g_cfg.tuner_addr = BOARD_TUNER_ADDR;
	g_cfg.tuner_xtal = SONY_ASCOT3_XTAL_24000KHz;
	g_cfg.ts_clk = 1;
	g_cfg.ts_clk_mask = 1;
	g_cfg.lock_flag = 1;
	g_cfg.atsc3_output = SONY_DEMOD_OUTPUT_ATSC3_ALP_DIV_TS;
	struct dvb_frontend *fe = cxd2878_attach(&g_cfg, &g_i2c);
	if (fe) ((struct cxd2878_dev *)fe->demodulator_priv)->alpdev = &g_alp_netdev;
	return fe;
}

static u32 rf_to_hz(unsigned ch)
{
	if (ch >= 2 && ch <= 4) return (57 + (ch - 2) * 6) * 1000000u;
	if (ch >= 5 && ch <= 6) return (79 + (ch - 5) * 6) * 1000000u;
	if (ch >= 7 && ch <= 13) return (177 + (ch - 7) * 6) * 1000000u;
	if (ch >= 14 && ch <= 69) return (473 + (ch - 14) * 6) * 1000000u;
	return 0;
}

static int fe_tune(struct dvb_frontend *fe, int atsc3, u32 hz, u32 plp)
{
	struct dtv_frontend_properties *c = &fe->dtv_property_cache;
	unsigned delay;
	enum fe_status st = 0;
	c->delivery_system = atsc3 ? SYS_ATSC3 : SYS_ATSC;
	c->modulation = atsc3 ? QAM_AUTO : VSB_8;
	c->frequency = hz;
	c->bandwidth_hz = 6000000;
	c->inversion = INVERSION_AUTO;
	c->stream_id = plp;
	return fe->ops.tune(fe, true, 0, &delay, &st);
}

static void status_line(struct dvb_frontend *fe, enum fe_status st, char *out, size_t n)
{
	struct dtv_frontend_properties *c = &fe->dtv_property_cache;
	char rf[32] = "RF ?", snr[32] = "SNR ?", ber[40] = "";
	if (c->strength.len && c->strength.stat[0].scale == FE_SCALE_DECIBEL)
		snprintf(rf, sizeof(rf), "RF %6.2f dBm", c->strength.stat[0].svalue / 1000.0);
	if (c->cnr.len && c->cnr.stat[0].scale == FE_SCALE_DECIBEL)
		snprintf(snr, sizeof(snr), "SNR %6.2f dB", c->cnr.stat[0].svalue / 1000.0);
	if (c->delivery_system == SYS_ATSC3 && c->post_bit_error.len &&
	    c->post_bit_error.stat[0].scale == FE_SCALE_COUNTER)
		snprintf(ber, sizeof(ber), "  BER(preBCH) %.2e",
			 c->post_bit_error.stat[0].uvalue / 1e9);
	snprintf(out, n, "%s%s%s%s%s  %s  %s%s",
		 st & FE_HAS_SIGNAL ? "S" : "-", st & FE_HAS_CARRIER ? "C" : "-",
		 st & FE_HAS_VITERBI ? "V" : "-", st & FE_HAS_SYNC ? "Y" : "-",
		 st & FE_HAS_LOCK ? "L" : "-", rf, snr, ber);
}

/* ======================= main ======================= */

static void on_sig(int s) { (void)s; g_stop = 1; }

static void usage(const char *p)
{
	fprintf(stderr,
		"hdtvmate - native macOS driver for the GTMEDIA/Zenview HDTV Mate\n\n"
		"Usage:\n"
		"  %s info                         init bridge + detect demod, then exit\n"
		"  %s scan [first] [last] [-1|-3]   scan US RF channels (default 2-36)\n"
		"  %s tune <rfch|Hz> [options]      tune and monitor\n\n"
		"Options:\n"
		"  -1             ATSC 1.0 (8VSB)\n"
		"  -3             ATSC 3.0 (default)\n"
		"  -p <plp>       ATSC 3.0 PLP id (default: all)\n"
		"  -o <file|->    write raw TS (ATSC1: playable MPEG-TS; ATSC3: ALP-div-TS)\n"
		"  -w <file|->    ATSC 3.0: write decapsulated IP packets as pcap (Wireshark, atsc3play.py)\n"
		"  -t <sec>       stop after N seconds (default: until Ctrl-C)\n"
		"  -f <fw>        firmware file (default: ./dvb-usb-hdtvmate.fw)\n"
		"  -v             verbose (I2C/driver debug)\n", p, p, p);
}

int main(int argc, char **argv)
{
	const char *fw = getenv("HDTVMATE_FW") ? getenv("HDTVMATE_FW") : "dvb-usb-hdtvmate.fw";
	const char *tsout = NULL, *pcap = NULL;
	int atsc3 = 1, secs = 0, opt;
	u32 plp = NO_STREAM_ID_FILTER;
	int mode_scan = 0, scan_sys = 0;

	if (argc < 2) { usage(argv[0]); return 1; }
	const char *mode = argv[1];
	/* parse options anywhere (BSD getopt stops at first positional) */
	const char *pos[4];
	int npos = 0;
#ifdef __linux__
	const char *optstr = "+13p:o:w:t:f:vh";
#else
	const char *optstr = "13p:o:w:t:f:vh";
#endif
	optind = 2;
	while (optind < argc) {
		opt = getopt(argc, argv, optstr);
		if (opt == -1) {
			if (npos < 4) pos[npos++] = argv[optind];
			optind++;
			continue;
		}
		switch (opt) {
		case '1': atsc3 = 0; scan_sys = 1; break;
		case '3': atsc3 = 1; scan_sys = 3; break;
		case 'p': plp = strtoul(optarg, NULL, 0); break;
		case 'o': tsout = optarg; break;
		case 'w': pcap = optarg; break;
		case 't': secs = atoi(optarg); break;
		case 'f': fw = optarg; break;
		case 'v': kshim_verbose = 1; break;
		default: usage(argv[0]); return 1;
		}
	}

	u32 hz = 0;
	if (!strcmp(mode, "tune")) {
		if (npos < 1) { usage(argv[0]); return 1; }
		unsigned long v = strtoul(pos[0], NULL, 0);
		hz = v < 1000 ? rf_to_hz(v) : v;
		if (!hz) { fprintf(stderr, "bad channel/frequency\n"); return 1; }
	} else if (!strcmp(mode, "scan")) {
		mode_scan = 1;
	} else if (strcmp(mode, "info")) {
		usage(argv[0]); return 1;
	}

	signal(SIGINT, on_sig);
	signal(SIGTERM, on_sig);
	signal(SIGPIPE, SIG_IGN);

	if (bridge_open() || bridge_init(fw)) return 2;

	g_fe = frontend_attach();
	if (!g_fe) { fprintf(stderr, "demod attach failed\n"); return 3; }
	if (g_fe->ops.init(g_fe)) { fprintf(stderr, "demod init failed\n"); return 3; }
	fprintf(stderr, "[demod] CXD2878 initialized (chip id 0x%03x)\n",
		((struct cxd2878_dev *)g_fe->demodulator_priv)->chipid);
	if (!strcmp(mode, "info")) goto done;

	if (mode_scan) {
		unsigned first = 2, last = 36, found = 0;
		if (npos > 0) first = strtoul(pos[0], NULL, 0);
		if (npos > 1) last = strtoul(pos[1], NULL, 0);
		kshim_quiet = 1;
		fprintf(stderr, "Scanning RF %u-%u (ATSC 1.0 ~1.5 s + ATSC 3.0 ~3 s per channel; Ctrl-C to stop)\n",
			first, last);
		for (unsigned ch = first; ch <= last && !g_stop; ch++) {
			if (!rf_to_hz(ch)) continue;
			int locked = 0;
			char line[160] = "";
			for (int sys = 1; sys <= 3 && !g_stop && !locked; sys += 2) {
				if (scan_sys && scan_sys != sys) continue;
				enum fe_status st = 0;
				fprintf(stderr, "\r  RF %2u (%3u MHz) trying ATSC %s...            ", ch,
					rf_to_hz(ch) / 1000000, sys == 3 ? "3.0" : "1.0");
				fe_tune(g_fe, sys == 3, rf_to_hz(ch), NO_STREAM_ID_FILTER);
				int polls = sys == 3 ? 30 : 15;
				for (int i = 0; i < polls && !g_stop; i++) {
					msleep(100);
					g_fe->ops.read_status(g_fe, &st);
					if (st & FE_HAS_LOCK) break;
					/* ATSC 3.0 L1 detected but not locked yet: give it more time */
					if (sys == 3 && (st & FE_HAS_SIGNAL) && i == polls - 1 && polls < 60) polls = 60;
				}
				status_line(g_fe, st, line, sizeof(line));
				if (st & FE_HAS_LOCK) {
					fprintf(stderr, "\r  RF %2u (%3u MHz)  ATSC %s  LOCK   %s\n", ch,
						rf_to_hz(ch) / 1000000, sys == 3 ? "3.0" : "1.0", line);
					locked = 1;
					found++;
				}
			}
			if (!locked && kshim_verbose)
				fprintf(stderr, "\r  RF %2u  no lock  %s\n", ch, line);
		}
		fprintf(stderr, "\r%-60s\nScan done: %u station(s) locked.\n", "", found);
		goto done;
	}

	/* tune mode */
	g_atsc3 = atsc3;
	if (tsout) {
		g_ts_out = strcmp(tsout, "-") ? fopen(tsout, "wb") : stdout;
		if (!g_ts_out) { perror(tsout); return 1; }
		ring_start(&g_ts_ring, g_ts_out);
	}
	if (pcap && atsc3) {
		g_pcap = strcmp(pcap, "-") ? fopen(pcap, "wb") : stdout;
		if (!g_pcap) { perror(pcap); return 1; }
		pcap_header(g_pcap);
		fflush(g_pcap);
		ring_start(&g_pcap_ring, g_pcap);
	}
	if (atsc3) g_alp = alp_user_create(on_ip, NULL);

	fprintf(stderr, "Tuning %.3f MHz, ATSC %s%s\n", hz / 1e6, atsc3 ? "3.0" : "1.0",
		atsc3 ? (plp == NO_STREAM_ID_FILTER ? ", all PLPs" : "") : "");
	if (atsc3 && plp != NO_STREAM_ID_FILTER) fprintf(stderr, "PLP %u\n", plp);
	if (fe_tune(g_fe, atsc3, hz, plp)) fprintf(stderr, "tune returned error\n");

	if (streaming_start()) { fprintf(stderr, "streaming start failed\n"); goto done; }

	u64 last_bytes = 0;
	for (int t = 0; !g_stop && (!secs || t < secs); t++) {
		enum fe_status st = 0;
		char line[160];
		sleep(1);
		g_fe->ops.read_status(g_fe, &st);
		status_line(g_fe, st, line, sizeof(line));
		pthread_mutex_lock(&out_lock);
		u64 b = g_ts_bytes;
		double mbps = (b - last_bytes) * 8 / 1e6;
		last_bytes = b;
		if (atsc3 && g_alp) {
			const struct alp_stats *as = alp_user_stats(g_alp);
			fprintf(stderr, "[%4ds] %s  TS %.2f Mbps  IP pkts %llu  LLS %llu\n", t + 1, line,
				mbps, (unsigned long long)as->ip_packets, (unsigned long long)as->type_lls);
		} else {
			fprintf(stderr, "[%4ds] %s  TS %.2f Mbps  pkts %llu  TEI %llu  CC-err %llu\n", t + 1, line,
				mbps, (unsigned long long)g_ts_pkts, (unsigned long long)g_ts_tei,
				(unsigned long long)g_ts_cc_err);
		}
		pthread_mutex_unlock(&out_lock);
		if (g_ts_ring.dead || g_pcap_ring.dead) { fprintf(stderr, "output closed, stopping\n"); break; }
	}
	g_stop = 1;
	streaming_stop();
	ring_finish(&g_ts_ring, "TS");
	ring_finish(&g_pcap_ring, "pcap");

	if (atsc3 && g_nflows) {
		fprintf(stderr, "\nIP multicast flows seen:\n");
		for (int i = 0; i < g_nflows; i++)
			fprintf(stderr, "  %u.%u.%u.%u:%-5u  %8llu pkts  %10llu bytes\n",
				g_flows[i].dst >> 24, (g_flows[i].dst >> 16) & 0xff,
				(g_flows[i].dst >> 8) & 0xff, g_flows[i].dst & 0xff, g_flows[i].port,
				(unsigned long long)g_flows[i].pkts, (unsigned long long)g_flows[i].bytes);
	}
	if (atsc3) {
		struct cxd2878_alp_ts_stats *s = &((struct cxd2878_dev *)g_fe->demodulator_priv)->alp_ts_stats;
		fprintf(stderr, "ALP-TS: reassembled %llu  TEI %llu  sync-miss %llu  pusi-err %llu\n",
			(unsigned long long)s->ts_reassembled, (unsigned long long)s->ts_tei,
			(unsigned long long)s->ts_sync_miss, (unsigned long long)s->frame_err_pusi);
	}
	fprintf(stderr, "USB errors: %llu\n", (unsigned long long)g_usb_err);

done:
	if (g_fe && g_fe->ops.sleep) g_fe->ops.sleep(g_fe);
	if (g_ts_out && g_ts_out != stdout) fclose(g_ts_out);
	if (g_pcap && g_pcap != stdout) fclose(g_pcap);
	libusb_release_interface(B.h, 0);
	libusb_close(B.h);
	libusb_exit(B.ctx);
	return 0;
}
