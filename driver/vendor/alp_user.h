#ifndef _ALP_USER_H
#define _ALP_USER_H
#include "kshim.h"
#include "alp.h"
typedef void (*alp_ip_cb_t)(void *priv, const u8 *ip, u32 len);
struct alp_dev *alp_user_create(alp_ip_cb_t cb, void *priv);
const struct alp_stats *alp_user_stats(struct alp_dev *a);
#endif
