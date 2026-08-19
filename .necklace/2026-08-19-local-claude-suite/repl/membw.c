// Measure achievable host memory read bandwidth. On Strix Halo the GPU shares
// this same LPDDR5X, so this number is the ceiling on decode throughput:
// tokens/sec <= bandwidth / bytes-read-per-token.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <omp.h>

#define GB (1024ULL*1024ULL*1024ULL)

static double now(void){ struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec + t.tv_nsec*1e-9; }

int main(int argc, char **argv){
    size_t n = 4ULL*GB/sizeof(double);      // 4 GiB working set, far past any cache
    double *a = aligned_alloc(64, n*sizeof(double));
    if(!a){ perror("alloc"); return 1; }
    #pragma omp parallel for
    for(size_t i=0;i<n;i++) a[i] = 1.0;

    for(int rep=0; rep<3; rep++){
        double t0 = now();
        double s = 0.0;
        #pragma omp parallel for reduction(+:s)
        for(size_t i=0;i<n;i++) s += a[i];
        double dt = now()-t0;
        printf("read  %.1f GiB in %.4f s  ->  %7.1f GB/s   (checksum %.0f)\n",
               (double)(n*sizeof(double))/GB, dt,
               (double)(n*sizeof(double))/dt/1e9, s);
    }
    free(a);
    return 0;
}
