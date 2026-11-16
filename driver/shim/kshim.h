/*
 * kshim.h - minimal Linux-kernel API surface so the cxd2878 DVB demod
 * driver compiles unmodified as a userspace library (macOS/libusb).
 * Only what cxd2878.c actually uses is provided.
 */
#ifndef _KSHIM_H
#define _KSHIM_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <pthread.h>
#include <unistd.h>
#include <time.h>
#include "linux/types.h"
#include "dvb_frontend_uapi.h"

/* ---------------- misc kernel-isms ---------------- */
#define KBUILD_MODNAME "cxd2878"
#define THIS_MODULE NULL
#define MODULE_AUTHOR(x)
#define MODULE_DESCRIPTION(x)
#define MODULE_LICENSE(x)
#define EXPORT_SYMBOL(x)
#define EXPORT_SYMBOL_GPL(x)
#define __init
#define __exit
#define IS_REACHABLE(x) 1
#define LINUX_VERSION_CODE 0x060800
#define KERNEL_VERSION(a, b, c) (((a) << 16) + ((b) << 8) + (c))
#define GFP_KERNEL 0
#define GFP_ATOMIC 0
#define U8_MAX 0xff
#ifndef ENOTSUPP
#define ENOTSUPP 524
#endif
#define kHz 1000UL
#define MHz 1000000UL

#ifndef min
#define min(a, b) ((a) < (b) ? (a) : (b))
#endif
#ifndef max
#define max(a, b) ((a) > (b) ? (a) : (b))
#endif
#define min_t(t, a, b) ((t)(a) < (t)(b) ? (t)(a) : (t)(b))
#define max_t(t, a, b) ((t)(a) > (t)(b) ? (t)(a) : (t)(b))
#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))

static inline void *kzalloc(size_t n, int f) { (void)f; return calloc(1, n); }
static inline void *kmalloc(size_t n, int f) { (void)f; return malloc(n); }
static inline void kfree(const void *p) { free((void *)p); }

static inline void msleep(unsigned int ms) { usleep(ms * 1000u); }
static inline void usleep_range(unsigned long a, unsigned long b) { (void)b; usleep(a); }
static inline void udelay(unsigned long us) { usleep(us); }
static inline void mdelay(unsigned long ms) { usleep(ms * 1000u); }

/* jiffies as milliseconds (HZ=1000) */
static inline unsigned long kshim_jiffies(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (unsigned long)ts.tv_sec * 1000ul + ts.tv_nsec / 1000000ul;
}
#define jiffies kshim_jiffies()
#ifndef HZ
#define HZ 1000
#endif
#define msecs_to_jiffies(m) (m)
#define jiffies_to_msecs(j) (j)

/* ---------------- logging ---------------- */
struct device { const char *name; };
extern int kshim_verbose, kshim_quiet;
void kshim_log(int level, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
#define dev_err(d, fmt, ...)  kshim_log(0, fmt, ##__VA_ARGS__)
#define dev_warn(d, fmt, ...) kshim_log(1, fmt, ##__VA_ARGS__)
#define dev_info(d, fmt, ...) kshim_log(2, fmt, ##__VA_ARGS__)
#define dev_dbg(d, fmt, ...)  kshim_log(3, fmt, ##__VA_ARGS__)
#define KERN_ERR   ""
#define KERN_INFO  ""
#define KERN_DEBUG ""
#define KERN_WARNING ""
#define printk(fmt, ...) kshim_log(3, fmt, ##__VA_ARGS__)
#define pr_err(fmt, ...)  fprintf(stderr, fmt, ##__VA_ARGS__)
#define pr_info(fmt, ...) fprintf(stderr, fmt, ##__VA_ARGS__)

/* ---------------- mutex ---------------- */
struct mutex { pthread_mutex_t m; };
static inline void mutex_init(struct mutex *m)
{
	pthread_mutexattr_t a;
	pthread_mutexattr_init(&a);
	pthread_mutexattr_settype(&a, PTHREAD_MUTEX_RECURSIVE);
	pthread_mutex_init(&m->m, &a);
}
static inline void mutex_lock(struct mutex *m)   { pthread_mutex_lock(&m->m); }
static inline void mutex_unlock(struct mutex *m) { pthread_mutex_unlock(&m->m); }

/* ---------------- list ---------------- */
struct list_head { struct list_head *next, *prev; };
#define LIST_HEAD_INIT(n) { &(n), &(n) }
#define LIST_HEAD(n) struct list_head n = LIST_HEAD_INIT(n)
#define container_of(ptr, type, member) \
	((type *)((char *)(ptr) - offsetof(type, member)))
static inline void list_add(struct list_head *n, struct list_head *h)
{
	n->next = h->next; n->prev = h;
	h->next->prev = n; h->next = n;
}
static inline void list_del(struct list_head *e)
{
	e->prev->next = e->next; e->next->prev = e->prev;
	e->next = e->prev = e;
}
#define list_for_each_entry(pos, head, member) \
	for (pos = container_of((head)->next, __typeof__(*pos), member); \
	     &pos->member != (head); \
	     pos = container_of(pos->member.next, __typeof__(*pos), member))

/* ---------------- i2c ---------------- */
#define I2C_M_RD 0x0001
#define I2C_FUNC_I2C 0x1
struct i2c_msg { u16 addr; u16 flags; u16 len; u8 *buf; };
struct i2c_adapter {
	struct device dev;
	int (*xfer)(struct i2c_adapter *adap, struct i2c_msg *msgs, int num);
	void *priv;
	char name[48];
};
static inline int i2c_transfer(struct i2c_adapter *a, struct i2c_msg *m, int n)
{
	return a->xfer(a, m, n);
}

/* ---------------- net (ALP carrier) ---------------- */
struct net_device { int carrier; };
static inline void netif_carrier_on(struct net_device *d)  { if (d) d->carrier = 1; }
static inline void netif_carrier_off(struct net_device *d) { if (d) d->carrier = 0; }

/* ---------------- dvb frontend (in-kernel parts) ---------------- */
#define MAX_DELSYS 8
#ifndef SYS_ATSC3
#define SYS_ATSC3 35
#endif

enum dvbfe_algo {
	DVBFE_ALGO_HW = (1 << 0),
	DVBFE_ALGO_SW = (1 << 1),
	DVBFE_ALGO_CUSTOM = (1 << 2),
	DVBFE_ALGO_RECOVERY = (1 << 31),
};

struct dvb_frontend_internal_info {
	char name[128];
	u32 frequency_min_hz, frequency_max_hz;
	u32 frequency_stepsize_hz, frequency_tolerance_hz;
	u32 symbol_rate_min, symbol_rate_max, symbol_rate_tolerance;
	enum fe_caps caps;
};

struct dvb_frontend;
struct dvb_frontend_ops {
	struct dvb_frontend_internal_info info;
	u8 delsys[MAX_DELSYS];
	void (*release)(struct dvb_frontend *fe);
	int (*init)(struct dvb_frontend *fe);
	int (*sleep)(struct dvb_frontend *fe);
	int (*tune)(struct dvb_frontend *fe, bool re_tune, unsigned int mode_flags,
		    unsigned int *delay, enum fe_status *status);
	enum dvbfe_algo (*get_frontend_algo)(struct dvb_frontend *fe);
	int (*set_frontend)(struct dvb_frontend *fe);
	int (*read_status)(struct dvb_frontend *fe, enum fe_status *status);
	int (*read_ber)(struct dvb_frontend *fe, u32 *ber);
	int (*read_signal_strength)(struct dvb_frontend *fe, u16 *strength);
	int (*read_snr)(struct dvb_frontend *fe, u16 *snr);
	int (*read_ucblocks)(struct dvb_frontend *fe, u32 *ucblocks);
};

struct dtv_frontend_properties {
	u32 frequency;
	enum fe_modulation modulation;
	enum fe_sec_voltage voltage;
	enum fe_sec_tone_mode sectone;
	enum fe_spectral_inversion inversion;
	enum fe_code_rate fec_inner;
	enum fe_transmit_mode transmission_mode;
	u32 bandwidth_hz;
	enum fe_guard_interval guard_interval;
	enum fe_hierarchy hierarchy;
	u32 symbol_rate;
	enum fe_code_rate code_rate_HP;
	enum fe_code_rate code_rate_LP;
	enum fe_pilot pilot;
	enum fe_rolloff rolloff;
	enum fe_delivery_system delivery_system;
	u32 stream_id;
	u32 scrambling_sequence_index;
	struct dtv_fe_stats strength;
	struct dtv_fe_stats cnr;
	struct dtv_fe_stats pre_bit_error;
	struct dtv_fe_stats pre_bit_count;
	struct dtv_fe_stats post_bit_error;
	struct dtv_fe_stats post_bit_count;
	struct dtv_fe_stats block_error;
	struct dtv_fe_stats block_count;
};

struct dvb_adapter;
struct dvb_frontend {
	struct dvb_frontend_ops ops;
	struct dvb_adapter *dvb;
	void *demodulator_priv;
	void *tuner_priv;
	struct dtv_frontend_properties dtv_property_cache;
};

#define dvb_attach(f, ...) f(__VA_ARGS__)

#endif /* _KSHIM_H */
