# Standalone example constraints for a 50 MHz MiSTer-style system clock.
# A containing project may replace the period and boundary I/O delays, but the
# *_ASYNC and RESET_N exceptions must retain equivalent CDC/reset treatment.

create_clock -name CLK -period 20.000 [get_ports {CLK}]
derive_clock_uncertainty

# RESET_N asynchronously asserts all state. The framework must deassert it only
# after the clock is stable and hold it low for at least two CLK rising edges.
set_false_path -from [get_ports {RESET_N}]

# These level inputs terminate only at marked first-stage synchronizer flops.
set_false_path -from [get_ports {
    IRQ_ASYNC
    FIQ_ASYNC
    DEBUG_ENABLE_ASYNC
    DBGRQ_ASYNC
    DBGBREAK_ASYNC
    DBGEXT_ASYNC[*]
}]

# All remaining boundary signals are synchronous to CLK in this example.
set_input_delay -clock CLK -min 0.000 [get_ports {
    CPU_CE
    MEM_READY
    MEM_RDATA[*]
    MEM_ERROR
}]
set_input_delay -clock CLK -max 5.000 [get_ports {
    CPU_CE
    MEM_READY
    MEM_RDATA[*]
    MEM_ERROR
}]

set_output_delay -clock CLK -min 0.000 [get_ports {
    MEM_VALID
    MEM_ADDR[*]
    MEM_WRITE
    MEM_WDATA[*]
    MEM_BYTE_ENABLE[*]
    MEM_CODE
    MEM_PRIVILEGED
    MEM_LOCK
    MEM_SEQUENTIAL
    MEM_MORE
}]
set_output_delay -clock CLK -max 5.000 [get_ports {
    MEM_VALID
    MEM_ADDR[*]
    MEM_WRITE
    MEM_WDATA[*]
    MEM_BYTE_ENABLE[*]
    MEM_CODE
    MEM_PRIVILEGED
    MEM_LOCK
    MEM_SEQUENTIAL
    MEM_MORE
}]
