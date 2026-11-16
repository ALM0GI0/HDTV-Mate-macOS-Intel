/* Userspace stand-in for <linux/types.h> (macOS / Linux userspace). */
#ifndef _SHIM_LINUX_TYPES_H
#define _SHIM_LINUX_TYPES_H
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

typedef uint8_t  __u8;  typedef int8_t  __s8;
typedef uint16_t __u16; typedef int16_t __s16;
typedef uint32_t __u32; typedef int32_t __s32;
typedef uint64_t __u64; typedef int64_t __s64;
typedef uint8_t  u8;  typedef int8_t  s8;
typedef uint16_t u16; typedef int16_t s16;
typedef uint32_t u32; typedef int32_t s32;
typedef uint64_t u64; typedef int64_t s64;
typedef uintptr_t dma_addr_t;
#endif
