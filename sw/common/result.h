// result.h — SW pass/fail convention shared by all Phase 1 C tests.
//
// main() returns 0 on success, non-zero on failure. startup.S translates
// that into the .signature result word ('PASS' vs 0xDEAD) and halts with
// ebreak for the TB harness. Tests additionally print a "<NAME> OK"/"FAIL"
// line over UART: the TB matches the console string (mentor-critical
// channel) AND checks the signature word AND detects ebreak.
#ifndef SW_RESULT_H
#define SW_RESULT_H

#include <stdint.h>
#include "soc_map.h"

// Pinned word; defined by startup/linker's .signature section.
extern volatile uint32_t sw_result;

#define SW_OK 0
#define SW_FAIL 1

#endif // SW_RESULT_H
