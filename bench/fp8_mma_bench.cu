// SPDX-License-Identifier: MIT
/*
 * fp8_mma_bench: FP8 (E4M3) tensor-core instruction issue rate on sm_89.
 *
 * Why this exists: cuBLASLt exposes no FP8 GEMM algorithm on sm_89
 * (cublasLtMatmulAlgoGetHeuristic returns NOT_SUPPORTED / 0 results), and
 * WMMA has no FP8 fragment. NVIDIA's own Ada path for FP8 is the PTX
 * mma.sync.m16n8k32.e4m3.e4m3 instruction, so this probe issues that directly
 * and measures the register-resident issue rate the SM speed-select fuses gate.
 *
 * Shape parity with mma_bench: m16n8k32 = 2*16*8*32 = 8192 FLOPs per warp per
 * instruction, identical to mma_bench's m16n16k16 = 2*16*16*16 = 8192. So the
 * printed TF/s is directly comparable to mma_bench's f16/f32 row.
 *
 * This is an instruction issue rate, not a GEMM. The upstream 2705 report's
 * 59.326 -> 59.495 TF/s FP8 figure is a CUTLASS GEMM and will be lower; do not
 * compare across the two instruments.
 *
 * usage: fp8_mma_bench [iters] [reps]
 */
#include <cstdio>
#include <cstdlib>
#include <climits>
#include <cuda_runtime.h>
#include <cuda_fp8.h>

#define WARPS_PER_BLOCK 8
#define BLOCKS 1056            /* fixed grid, same as mma_bench for comparability */
#define CHAINS 8               /* independent accumulator chains per warp */
#define FP8_FLOPS 8192.0       /* 2 * 16 * 8 * 32 */

__global__ void bench_fp8_mma(unsigned long long iters, float *sink)
{
    /* E4M3 bit pattern 0x38 == 1.0f, so the accumulators stay finite and the
     * compiler cannot fold the chain (the sink test below can never be true). */
    unsigned a[4], b[2];
    float c[CHAINS][4];
    int t = threadIdx.x & 31;

    for (int i = 0; i < 4; i++) a[i] = 0x38383838u ^ (unsigned)(t * 0x01010101u);
    for (int i = 0; i < 2; i++) b[i] = 0x38383838u ^ (unsigned)(t * 0x00010001u);
#pragma unroll
    for (int j = 0; j < CHAINS; j++)
        for (int e = 0; e < 4; e++) c[j][e] = 0.0f;

    for (unsigned long long i = 0; i < iters; i++) {
#pragma unroll
        for (int j = 0; j < CHAINS; j++) {
            asm volatile(
                "mma.sync.aligned.m16n8k32.row.col.f32.e4m3.e4m3.f32 "
                "{%0,%1,%2,%3}, {%4,%5,%6,%7}, {%8,%9}, {%10,%11,%12,%13};\n"
                : "=f"(c[j][0]), "=f"(c[j][1]), "=f"(c[j][2]), "=f"(c[j][3])
                : "r"(a[0]), "r"(a[1]), "r"(a[2]), "r"(a[3]),
                  "r"(b[0]), "r"(b[1]),
                  "f"(c[j][0]), "f"(c[j][1]), "f"(c[j][2]), "f"(c[j][3]));
        }
    }

    float carry = 0.0f;
#pragma unroll
    for (int j = 0; j < CHAINS; j++)
        for (int e = 0; e < 4; e++) carry += c[j][e];
    if (carry == 2147483647.0f)          /* never true: keeps the loop alive */
        sink[threadIdx.x] = 1.0f;
}

int main(int argc, char **argv)
{
    unsigned long long iters = 20000;
    int reps = 3;
    if (argc > 3 ||
        (argc > 1 && (argv[1][0] < '0' || argv[1][0] > '9')) ||
        (argc > 2 && (argv[2][0] < '0' || argv[2][0] > '9'))) {
        std::fprintf(stderr, "usage: %s [positive iterations] [positive repetitions]\n", argv[0]);
        return 2;
    }
    if (argc > 1) iters = strtoull(argv[1], nullptr, 0);
    if (argc > 2) reps = atoi(argv[2]);
    if (!iters || reps < 1 || reps > INT_MAX) return 2;

    cudaDeviceProp prop;
    if (cudaGetDeviceProperties(&prop, 0) != cudaSuccess) {
        std::fprintf(stderr, "no device\n"); return 2;
    }
    if (prop.major < 8 || (prop.major == 8 && prop.minor < 9)) {
        std::fprintf(stderr, "FP8 mma requires sm_89+, this is sm_%d%d\n", prop.major, prop.minor);
        return 2;
    }

    float *sink = nullptr;
    if (cudaMalloc(&sink, 256 * sizeof(float)) != cudaSuccess) return 2;
    cudaMemset(sink, 0, 256 * sizeof(float));

    std::printf("# %s, %d SMs, sm_%d%d, iters=%llu reps=%d\n",
                prop.name, prop.multiProcessorCount, prop.major, prop.minor, iters, reps);

    double warps = (double)BLOCKS * WARPS_PER_BLOCK;
    double best = 0.0;
    std::printf("mode          best TF/s  median TF/s   runs\n");
    double samples[64];
    int n = 0;

    /* warmup */
    bench_fp8_mma<<<BLOCKS, WARPS_PER_BLOCK * 32>>>(iters / 8 ? iters / 8 : 1, sink);
    cudaDeviceSynchronize();
    cudaError_t e = cudaGetLastError();
    if (e != cudaSuccess) {
        std::fprintf(stderr, "kernel launch failed: %s\n", cudaGetErrorString(e));
        return 1;
    }

    for (int r = 0; r < reps && r < 64; r++) {
        cudaEvent_t t0, t1;
        cudaEventCreate(&t0); cudaEventCreate(&t1);
        cudaEventRecord(t0);
        bench_fp8_mma<<<BLOCKS, WARPS_PER_BLOCK * 32>>>(iters, sink);
        cudaEventRecord(t1);
        cudaEventSynchronize(t1);
        float ms = 0.f;
        cudaEventElapsedTime(&ms, t0, t1);
        cudaEventDestroy(t0); cudaEventDestroy(t1);
        double secs = ms / 1000.0;
        double tf = warps * CHAINS * (double)iters * FP8_FLOPS / secs / 1e12;
        samples[n++] = tf;
        if (tf > best) best = tf;
    }

    double sorted[64];
    for (int i = 0; i < n; i++) sorted[i] = samples[i];
    for (int i = 0; i < n; i++)
        for (int j = i + 1; j < n; j++)
            if (sorted[j] < sorted[i]) { double t = sorted[i]; sorted[i] = sorted[j]; sorted[j] = t; }
    double med = sorted[n / 2];

    std::printf("e4m3/f32 %14.2f %12.2f   ", best, med);
    for (int i = 0; i < n; i++) std::printf("%s%.1f", i ? "/" : "", samples[i]);
    std::printf("\n");
    std::printf("\n(instruction issue rate, not a GEMM; compare to mma_bench f16/f32,\n"
                " not to the report's 59.3 TF/s CUTLASS number)\n");

    cudaFree(sink);
    return 0;
}
