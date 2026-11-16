// SPDX-License-Identifier: GPL-2.0-only
/*
 * Userspace build of the cxd28xx ALP (ATSC A/330) parser.
 * Parsing/reassembly code (alp_seg_*, alp_handle_*, alp_process, alp_feed)
 * is copied verbatim from koreapyj/cxd28xx alp.c; the kernel net_device
 * delivery is replaced by a callback (used to write pcap / forward UDP).
 */
#include "kshim.h"
#include "alp.h"
#include "alp_user.h"

struct alp_dev {
	alp_ip_cb_t         ip_cb;
	void               *cb_priv;
	u8                 *seg_buf;
	u32                 seg_len;
	u8                  seg_type;
	u8                  seg_next_sn;
	bool                seg_active;
	struct alp_stats    stats;
};

struct alp_dev *alp_user_create(alp_ip_cb_t cb, void *priv)
{
	struct alp_dev *a = kzalloc(sizeof(*a), GFP_KERNEL);
	if (!a) return NULL;
	a->seg_buf = kmalloc(ALP_SEG_BUF_SIZE, GFP_KERNEL);
	a->ip_cb = cb;
	a->cb_priv = priv;
	return a;
}

const struct alp_stats *alp_user_stats(struct alp_dev *a) { return &a->stats; }

static void alp_deliver_ipv4(struct alp_dev *alp, const u8 *data, u32 len)
{
	if (len < 20) {
		alp->stats.short_packets++;
		return;
	}
	alp->stats.ip_packets++;
	alp->stats.ip_bytes += len;
	if (alp->ip_cb)
		alp->ip_cb(alp->cb_priv, data, len);
}

static void alp_deliver_lls(struct alp_dev *alp,
			    const u8 *payload, u32 payload_len)
{
	alp->stats.type_lls++;
}

/* Dispatch a single complete ALP payload by type */
static void alp_dispatch(struct alp_dev *alp, u8 packet_type,
			 const u8 *payload, u32 payload_len)
{
	switch (packet_type) {
	case ALP_TYPE_IPV4:
		alp_deliver_ipv4(alp, payload, payload_len);
		break;
	case ALP_TYPE_COMPRESSED_IP:
		alp->stats.type_compressed_ip++;
		break;
	case ALP_TYPE_LLS:
		alp_deliver_lls(alp, payload, payload_len);
		break;
	case ALP_TYPE_TYPE_EXT:
		alp->stats.type_ext++;
		break;
	case ALP_TYPE_MPEG2_TS:
		alp->stats.type_ts++;
		break;
	default:
		alp->stats.type_unknown++;
		break;
	}
}

static void alp_seg_reset(struct alp_dev *alp)
{
	alp->seg_len = 0;
	alp->seg_next_sn = 0;
	alp->seg_active = false;
}

static void alp_handle_segmented(struct alp_dev *alp, u8 packet_type,
				 const u8 *buf, u32 len)
{
	u16 alp_length;
	u8 addhdr, seg_sn, lsi, sif, hef;
	u32 hdr_size;
	const u8 *payload;
	u16 payload_len;

	if (len < 3) {
		alp->stats.short_packets++;
		return;
	}

	alp_length = ((buf[0] & 0x07) << 8) | buf[1];
	addhdr = buf[2];
	seg_sn = (addhdr >> 3) & 0x1F;
	lsi    = (addhdr >> 2) & 1;
	sif    = (addhdr >> 1) & 1;
	hef    =  addhdr       & 1;

	/* Header: 2 (base) + 1 (seg additional) + SIF + HEF(skip) */
	hdr_size = 3;
	if (sif) hdr_size += 1;
	if (hef) hdr_size += 1;

	if (alp_length + 2 > len) {
		alp->stats.frame_err_seg++;
		alp_seg_reset(alp);
		return;
	}

	payload = buf + hdr_size;
	payload_len = alp_length - (hdr_size - 2);

	if (seg_sn == 0) {
		alp_seg_reset(alp);
		alp->seg_active = true;
		alp->seg_type = packet_type;
		alp->seg_next_sn = 1;
	} else if (!alp->seg_active ||
		   seg_sn != alp->seg_next_sn ||
		   packet_type != alp->seg_type) {
		alp->stats.seg_errors++;
		alp_seg_reset(alp);
		return;
	} else {
		alp->seg_next_sn = seg_sn + 1;
	}

	if (!alp->seg_buf ||
	    alp->seg_len + payload_len > ALP_SEG_BUF_SIZE) {
		alp->stats.seg_errors++;
		alp_seg_reset(alp);
		return;
	}
	memcpy(alp->seg_buf + alp->seg_len, payload, payload_len);
	alp->seg_len += payload_len;

	if (lsi) {
		alp->stats.seg_completed++;
		alp_dispatch(alp, alp->seg_type,
			     alp->seg_buf, alp->seg_len);
		alp_seg_reset(alp);
	}
}

/* ── ALP concatenation (A/330 §5.1.2.3) ───────────────────────────── */

static void alp_handle_concatenated(struct alp_dev *alp, u8 packet_type,
				    const u8 *buf, u32 len)
{
	u16 alp_length, total_payload;
	u8 length_msb, count, sif;
	u32 hdr_bits_offset, hdr_size;
	u16 comp_len[9];
	u32 i, num_packets, offset;
	u32 sum_comp;

	if (len < 3) {
		alp->stats.short_packets++;
		return;
	}

	alp_length = ((buf[0] & 0x07) << 8) | buf[1];

	length_msb = (buf[2] >> 4) & 0x0F;
	count      = (buf[2] >> 1) & 0x07;
	sif        =  buf[2]       & 1;

	total_payload = (length_msb << 11) | alp_length;
	num_packets = count + 2;

	hdr_bits_offset = 24;

	for (i = 0; i < count + 1; i++) {
		u32 byte_off = hdr_bits_offset / 8;
		u32 bit_off  = hdr_bits_offset % 8;

		if (byte_off + 2 > len) {
			alp->stats.frame_err_concat++;
			return;
		}

		if (bit_off <= 4) {
			comp_len[i] = ((buf[byte_off] << 8) | buf[byte_off + 1])
				>> (4 - bit_off);
		} else {
			comp_len[i] = ((buf[byte_off] << 16) |
				       (buf[byte_off + 1] << 8) |
				       buf[byte_off + 2])
				>> (12 - (bit_off - 4));
		}
		comp_len[i] &= 0x0FFF;
		hdr_bits_offset += 12;
	}

	if ((count & 1) == 0)
		hdr_bits_offset += 4;

	hdr_size = (hdr_bits_offset + 7) / 8;
	if (sif) hdr_size += 1;

	u32 addl_hdr_size = hdr_size - 2;
	u32 data_len;

	if (total_payload < addl_hdr_size) {
		alp->stats.frame_err_concat++;
		return;
	}
	data_len = total_payload - addl_hdr_size;

	if (hdr_size + data_len > len) {
		alp->stats.frame_err_concat++;
		return;
	}

	offset = hdr_size;
	sum_comp = 0;

	for (i = 0; i < num_packets; i++) {
		u16 pkt_len;

		if (i < count + 1) {
			pkt_len = comp_len[i];
		} else {
			if (data_len < sum_comp) {
				alp->stats.frame_err_concat++;
				return;
			}
			pkt_len = data_len - sum_comp;
		}

		if (offset + pkt_len > len) {
			alp->stats.frame_err_concat++;
			return;
		}

		alp->stats.concat_delivered++;
		alp_dispatch(alp, packet_type, buf + offset, pkt_len);
		offset += pkt_len;
		sum_comp += pkt_len;
	}
}

/* ── ALP packet processing ─────────────────────────────────────────── */

void alp_process(struct alp_dev *alp, const u8 *buf, u32 len)
{
	u8 packet_type;
	u8 pc, header_mode;
	u16 alp_length;
	u32 hdr_size;
	const u8 *payload;
	u16 payload_len;

	if (!alp)
		return;

	if (len < 2) {
		alp->stats.short_packets++;
		return;
	}

	packet_type = (buf[0] >> 5) & 0x07;
	pc = (buf[0] >> 4) & 1;

	if (pc) {
		u8 sc = (buf[0] >> 3) & 1;

		if (sc == 0)
			alp_handle_segmented(alp, packet_type, buf, len);
		else
			alp_handle_concatenated(alp, packet_type, buf, len);
		return;
	}

	/* payload_configuration=0: single packet */
	header_mode = (buf[0] >> 3) & 1;
	alp_length = ((buf[0] & 0x07) << 8) | buf[1];

	if (header_mode) {
		if (len < 3) {
			alp->stats.short_packets++;
			return;
		}

		u8 addl = buf[2];
		u8 sif = (addl >> 1) & 1;
		u8 hef = addl & 1;

		hdr_size = 3 + (sif ? 1 : 0);
		if (hef) {
			if (hdr_size + 2 > len) {
				alp->stats.short_packets++;
				return;
			}
			u8 ext_len_m1 = buf[hdr_size + 1];
			hdr_size += 2 + ext_len_m1 + 1;
		}

		/* Only deliver types we can process */
		switch (packet_type) {
		case ALP_TYPE_IPV4:
			break;
		case ALP_TYPE_COMPRESSED_IP:
			alp->stats.ext_hdr_compressed_ip++; return;
		case ALP_TYPE_LLS:
			alp->stats.ext_hdr_lls++; return;
		case ALP_TYPE_TYPE_EXT:
			alp->stats.ext_hdr_ext++; return;
		case ALP_TYPE_MPEG2_TS:
			alp->stats.ext_hdr_ts++; return;
		default:
			alp->stats.ext_hdr_unknown++; return;
		}
	} else {
		hdr_size = 2;
	}

	if (hdr_size > len) {
		alp->stats.short_packets++;
		return;
	}

	payload = buf + hdr_size;
	if (hdr_size - 2 >= alp_length) {
		/* Header consumes entire length — no payload */
		return;
	}
	payload_len = alp_length - (hdr_size - 2);

	alp_dispatch(alp, packet_type, payload, payload_len);
}
EXPORT_SYMBOL_GPL(alp_process);

/*
 * Determine total size of the ALP packet at the start of buf.
 * Returns 0 if insufficient data to determine the size.
 */
static u32 alp_peek_total_size(const u8 *buf, u32 len)
{
	u16 alp_length;

	if (len < 2)
		return 0;

	alp_length = ((buf[0] & 0x07) << 8) | buf[1];

	if ((buf[0] & 0x18) == 0x18) {
		/* PC=1, S/C=1 (concatenated): 4 MSB in byte 2 */
		if (len < 3)
			return 0;
		alp_length |= ((u16)(buf[2] >> 4) & 0x0F) << 11;
		return 2 + alp_length;
	}

	if ((buf[0] & 0x18) == 0x08) {
		/* PC=0, HM=1 (extended header): 5 MSB in byte 2 */
		u8 addl, sif, hef;
		u32 full_length, hdr;

		if (len < 3)
			return 0;
		addl = buf[2];
		sif = (addl >> 1) & 1;
		hef = addl & 1;
		full_length = (((u32)(addl >> 3) & 0x1F) << 11) | alp_length;
		hdr = 3 + (sif ? 1 : 0);
		if (hef) {
			if (len < hdr + 2)
				return 0;
			hdr += 2 + buf[hdr + 1] + 1;
		}
		return hdr + full_length;
	}

	return 2 + alp_length;
}

u32 alp_feed(struct alp_dev *alp, const u8 *buf, u32 len)
{
	u32 pos = 0;

	if (!alp)
		return 0;

	while (pos < len) {
		u32 remaining = len - pos;
		u32 total = alp_peek_total_size(buf + pos, remaining);

		if (total == 0 || total > remaining)
			break;

		alp_process(alp, buf + pos, total);
		pos += total;
	}

	return pos;
}
EXPORT_SYMBOL_GPL(alp_feed);

/* ── Net device operations ─────────────────────────────────────────── */
