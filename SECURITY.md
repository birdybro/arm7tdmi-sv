# Security

This CPU is not a security boundary. ARM7TDMI-S provides no MMU, MPU, memory
encryption, privilege isolation suitable for hostile code, secure boot, or
side-channel countermeasures. A containing system must enforce memory and
peripheral access policy.

The optional debug profile exposes halt/monitor controls, register access,
watchpoints, breakpoints, CP14 communications, and JTAG scan behavior.
Production designs must keep `ENABLE_DEBUG=0` unless those capabilities are
required, control `DEBUG_ENABLE_ASYNC`/DBGEN from trusted policy, and protect
or remove any external transport. Disabling the public debug parameter is
the supported way to tie internal requests off; it is not a substitute for
board-level access control if another master can read memory.

Memory adapters propagate privilege and lock metadata but do not authenticate
masters or arbitrate policy. Integrators must prevent untrusted DMA or bus
masters from observing locked CPU transactions or modifying executable code.
The CPU has no cache; a redirect after a completed code write refetches the
destination, which makes writable executable memory especially sensitive.

Report sensitive vulnerabilities through a private GitHub Security Advisory
when that facility is available for the repository. Use a normal issue only
for reports that contain no exploit, secret, copyrighted firmware, or private
system information.
