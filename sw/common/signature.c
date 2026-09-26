// signature.c — pins the TB-visible result word at 0x0000_7FF0.
// See sw/common/linker.ld (.signature) and soc_map.h (SOC_SW_RESULT_ADDR).
#include <stdint.h>

__attribute__((section(".signature"))) volatile uint32_t sw_result = 0;
