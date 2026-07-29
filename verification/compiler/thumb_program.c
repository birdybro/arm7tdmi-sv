#include <stdint.h>

extern uint32_t arm_mix(uint32_t value, uint32_t step);

__attribute__((noinline))
uint32_t thumb_accumulate(uint32_t seed, uint32_t count)
{
    uint32_t value = seed;
    for (uint32_t step = 1; step <= count; ++step)
        value = arm_mix(value, step);
    return value;
}

__attribute__((noinline))
void thumb_store(volatile uint32_t *base, uint32_t value)
{
    volatile uint16_t *halfwords = (volatile uint16_t *)base;
    volatile uint8_t *bytes = (volatile uint8_t *)base;

    base[0] = value;
    halfwords[2] = (uint16_t)(value + 0x1234u);
    bytes[6] = (uint8_t)(value ^ 0xa5u);
}
