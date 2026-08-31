/* membw_probe.c — STREAM-triad memory-bandwidth probe
 * (built on demand by numa_autopin.sh)
 *
 * Pins each thread to a given CPU, first-touch-allocates under a given memory
 * policy, then prints the summed effective bandwidth (GB/s) of an a[i] = b[i] +
 * s*c[i] loop. No libnuma needed — calls set_mempolicy(2) directly.
 *
 * usage: membw_probe SECONDS MB_PER_ARRAY POLICY CPU [CPU...]
 *   - SECONDS: per-thread measurement duration in seconds (float, e.g. 0.6, 2)
 *   - MB_PER_ARRAY: size of each array a,b,c per thread, in MiB
 *   - POLICY: local | bind:<node> | interleave:<n0,n1,...>
 *   - CPU [CPU...]: one thread pinned to each listed logical CPU
 * output: "GBPS <sum over all threads>"
 *
 * build: cc -O3 -march=native -pthread -o membw_probe membw_probe.c
 */
#define _GNU_SOURCE
#include <pthread.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

#define MPOL_BIND_ 2
#define MPOL_INTERLEAVE_ 3

static double now(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec + ts.tv_nsec * 1e-9;
}

typedef struct {
  int cpu;
  int mode;
  unsigned long mask;
  size_t n;
  double secs;
  double gbps;
  volatile double sink;
} targ;

static pthread_barrier_t bar;

static void *worker(void *arg) {
  targ *t = arg;
  cpu_set_t cs;
  CPU_ZERO(&cs);
  CPU_SET(t->cpu, &cs);
  if (sched_setaffinity(0, sizeof cs, &cs)) {
    perror("sched_setaffinity");
    exit(2);
  }
  /* maxnode counts bits the kernel may scan in the mask. Bound it to the mask's
   * own width (sizeof(mask)*8) so the kernel reads exactly one long and never
   * past &t->mask into the adjacent struct field. */
  if (t->mode &&
      syscall(SYS_set_mempolicy, t->mode, &t->mask, sizeof(t->mask) * 8)) {
    perror("set_mempolicy");
    exit(2);
  }
  size_t n = t->n;
  double *a = malloc(n * sizeof(double));
  double *b = malloc(n * sizeof(double));
  double *c = malloc(n * sizeof(double));
  if (!a || !b || !c) {
    fprintf(stderr, "alloc failed\n");
    exit(2);
  }
  /* first-touch: pages land on the node chosen by the policy set above */
  for (size_t i = 0; i < n; i++) {
    a[i] = 1.0;
    b[i] = 2.0;
    c[i] = 0.5;
  }
  pthread_barrier_wait(&bar);
  double t0 = now(), bytes = 0, s = 3.0, el;
  do {
    for (size_t i = 0; i < n; i++)
      a[i] = b[i] + s * c[i];
    __asm__ __volatile__("" ::: "memory");
    bytes += 3.0 * n * sizeof(double);
    s = a[n / 2] * 1e-9 + 3.0; /* defeat constant propagation */
  } while ((el = now() - t0) < t->secs);
  t->gbps = bytes / el / 1e9;
  t->sink = a[1];
  free(a);
  free(b);
  free(c);
  return NULL;
}

int main(int argc, char **argv) {
  if (argc < 5) {
    fprintf(stderr,
            "usage: %s SECONDS MB_PER_ARRAY POLICY CPU [CPU...]\n"
            "  POLICY: local | bind:<node> | interleave:<n0,n1,...>\n",
            argv[0]);
    return 1;
  }
  double secs = atof(argv[1]);
  size_t n = (size_t)atol(argv[2]) * 1024 * 1024 / sizeof(double);
  int mode = 0;
  unsigned long mask = 0;
  if (!strncmp(argv[3], "bind:", 5)) {
    mode = MPOL_BIND_;
    mask = 1UL << atoi(argv[3] + 5);
  } else if (!strncmp(argv[3], "interleave:", 11)) {
    mode = MPOL_INTERLEAVE_;
    char *tok = strtok(argv[3] + 11, ",");
    while (tok) {
      mask |= 1UL << atoi(tok);
      tok = strtok(NULL, ",");
    }
  }
  int nt = argc - 4;
  targ *ts = calloc(nt, sizeof(targ));
  pthread_t *th = malloc(nt * sizeof(pthread_t));
  pthread_barrier_init(&bar, NULL, nt);
  for (int i = 0; i < nt; i++) {
    ts[i] = (targ){.cpu = atoi(argv[4 + i]),
                   .mode = mode,
                   .mask = mask,
                   .n = n,
                   .secs = secs};
    pthread_create(&th[i], NULL, worker, &ts[i]);
  }
  double sum = 0;
  for (int i = 0; i < nt; i++) {
    pthread_join(th[i], NULL);
    sum += ts[i].gbps;
  }
  printf("GBPS %.2f\n", sum);
  return 0;
}
