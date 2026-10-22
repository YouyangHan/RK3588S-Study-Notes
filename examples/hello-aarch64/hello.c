#include <stdio.h>
#ifdef __aarch64__
#include <sys/utsname.h>
#endif

int main(void)
{
    printf("Hello from RK3588 cross-compile demo!\n");
#ifdef __aarch64__
    printf("Built for: aarch64 (ARM64)\n");
#endif
    return 0;
}
