// hello-vyb — minimal C package used as the seed source for the BUILD-STAGE
// derivation spike (build/build-derive.vyb). A tiny real source that the
// derivation realizes into the store and then compiles with the (host) C
// toolchain, content-addressing the OUTPUT — the shape that later derives
// busybox and the Linux kernel "like the rest of the packages".
#include <stdio.h>

int main(void) {
    printf("hello vyb build derivation\n");
    return 0;
}
