/* Minimal static devmem: read 32-bit MMIO words via /dev/mem.
   usage: devmem <hexaddr> [count]   (count words, default 1) */
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdint.h>
#include <sys/mman.h>
int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <addr> [count]\n", argv[0]); return 2; }
    uint64_t addr = strtoull(argv[1], 0, 0);
    int count = argc > 2 ? atoi(argv[2]) : 1;
    int fd = open("/dev/mem", O_RDONLY | O_SYNC);
    if (fd < 0) { perror("open /dev/mem"); return 1; }
    long ps = sysconf(_SC_PAGESIZE);
    uint64_t base = addr & ~((uint64_t)ps - 1), off = addr - base;
    size_t len = off + (size_t)count * 4;
    void *m = mmap(0, len, PROT_READ, MAP_SHARED, fd, base);
    if (m == MAP_FAILED) { perror("mmap"); return 1; }
    volatile uint32_t *p = (volatile uint32_t *)((char *)m + off);
    for (int i = 0; i < count; i++)
        printf("0x%08llx: 0x%08x\n", (unsigned long long)(addr + i * 4), p[i]);
    return 0;
}
