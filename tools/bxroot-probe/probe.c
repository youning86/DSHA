/* B0 判定探针：只看 sysconf(_SC_SIGSTKSZ) 在本机 glibc 上的行为。
 *
 * 为什么是它：issue #148 在 4.14 内核上看到 glibc 内部断言
 *   Fatal glibc error: ../sysdeps/unix/sysv/linux/sysconf-sigstksz.h:25
 *   (sysconf_sigstksz): assertion failed: minsigstacksize != 0
 * 断言来自 libc 的 __libc_assert_fail，值来自 ld.so 的
 * GLRO(dl_minsigstacksize)。本探针把"谁被断言打死、值是多少"变成可观测输出。
 *
 * 每个阶段都 flush：断言是 abort()，最后打印出来的一行就是故障点。
 * 本文件只用于诊断，不参与生产构建、不改动 tools/bxroot 的锁定输入。
 */
#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <sys/auxv.h>
#include <unistd.h>

/* 老 <elf.h> 不一定有；AT_MINSIGSTKSZ 在 Linux 上是 51。 */
#ifndef AT_MINSIGSTKSZ
#define AT_MINSIGSTKSZ 51
#endif

int main(void)
{
    /* 1) 先看内核/加载器到底有没有给这一项（0 = 未提供）。 */
    errno = 0;
    unsigned long mp = (unsigned long) getauxval(AT_MINSIGSTKSZ);
    printf("B0_STAGE=AUXV AT_MINSIGSTKSZ=%lu errno=%d\n", mp, errno);
    fflush(stdout);

    /* 2) _SC_MINSIGSTKSZ：glibc 在 libc 内部同样有 assert != 0。 */
    errno = 0;
    long min = sysconf(_SC_MINSIGSTKSZ);
    printf("B0_STAGE=MINSIGSTKSZ value=%ld errno=%d\n", min, errno);
    fflush(stdout);

    /* 3) _SC_SIGSTKSZ：issue 里真正断言的那一个。 */
    errno = 0;
    long sig = sysconf(_SC_SIGSTKSZ);
    printf("B0_STAGE=SIGSTKSZ value=%ld errno=%d\n", sig, errno);
    fflush(stdout);

    printf("B0_STAGE=DONE pid=%ld\n", (long) getpid());
    return 0;
}
