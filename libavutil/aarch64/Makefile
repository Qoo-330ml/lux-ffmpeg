OBJS += aarch64/cpu.o                                                 \
        aarch64/float_dsp_init.o                                      \
        aarch64/tx_float_init.o                                       \

# lux: aarch64/crc.S is delivered under the GNU GPL v2 or later upstream (unlike
# the rest of libavutil/aarch64), and ARMV8-OBJS is not gated by CONFIG_GPL, so a
# --disable-gpl build would put GPL code into the LGPL libavutil. Only build it
# for GPL builds; LGPL builds also pass --disable-arm-crc so nothing references
# ff_crc32_aarch64() and the C fallback in libavutil/crc.c is used instead.
ifeq ($(CONFIG_GPL),yes)
ARMV8-OBJS += aarch64/crc.o
endif

NEON-OBJS += aarch64/float_dsp_neon.o                                 \
             aarch64/tx_float_neon.o                                  \

SVE-OBJS += aarch64/cpu_sve.o                                         \

SME-OBJS += aarch64/cpu_sme.o                                         \
