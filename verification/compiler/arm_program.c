#include <stdint.h>

#define MAILBOX ((volatile uint32_t *)0x00008000u)
#define MAILBOX_DONE 0xd06e0009u

extern uint32_t thumb_accumulate(uint32_t seed, uint32_t count);
extern void thumb_store(volatile uint32_t *base, uint32_t value);

__attribute__((noinline))
uint32_t arm_mix(uint32_t value, uint32_t step)
{
    return (value ^ (step * 3u)) + 0x11u;
}

__attribute__((noreturn))
void arm_main(void)
{
    uint32_t accumulated = thumb_accumulate(7u, 5u);
    uint32_t mixed = arm_mix(accumulated, 9u);

    MAILBOX[0] = 0x434f4d50u;
    MAILBOX[1] = accumulated;
    MAILBOX[2] = mixed;
    thumb_store(&MAILBOX[4], accumulated);
    MAILBOX[3] = MAILBOX[4] ^ MAILBOX[5];
    MAILBOX[7] = MAILBOX_DONE;

    for (;;)
        __asm__ volatile ("nop");
}
