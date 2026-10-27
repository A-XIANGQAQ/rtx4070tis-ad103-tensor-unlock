// SPDX-License-Identifier: MIT
/*
 * FP8 (E4M3) GEMM throughput probe for the AD103 unlock.
 *
 * DLSS 5's neural renderer runs "FP8 activations, FP16 accumulation"
 * (OpenDLSS-NR, bit-exact against NVIDIA 310.8.0). The upstream 2705 report
 * measured one E4M3/FP32 CUTLASS GEMM at 59.326 -> 59.495 TF/s (ratio 1.0029,
 * i.e. no gain) on the same card model this port targets. This probe gives a
 * second, independent FP8 data point through cuBLASLt instead of CUTLASS.
 *
 * Modes:
 *   e4m3_f32   E4M3 inputs, FP32 accumulate  <- the DLSS 5 shape
 *   e4m3_f16   E4M3 inputs, FP16 accumulate  <- fp16-accum variant
 *   fp16_f32   control (expected to double after a successful unlock)
 *
 * usage: fp8_bench [N] [iters] [reps]
 */
#include <cuda_runtime.h>
#include <cublasLt.h>
#include <cuda_fp8.h>
#include <cuda_fp16.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <vector>
#include <random>
#include <algorithm>
#include <chrono>

#define CK(x) do { cudaError_t e_=(x); if(e_!=cudaSuccess){ \
  std::fprintf(stderr,"CUDA error %s (%s:%d)\n",cudaGetErrorString(e_),__FILE__,__LINE__); \
  std::exit(1);} } while(0)
#define LK(x) do { cublasStatus_t s_=(x); if(s_!=CUBLAS_STATUS_SUCCESS){ \
  std::fprintf(stderr,"cuBLASLt error %d (%s:%d)\n",(int)s_,__FILE__,__LINE__); \
  std::exit(1);} } while(0)

__global__ void quant_e4m3(const float *src, __nv_fp8_e4m3 *dst, long n) {
    long i = (long)blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) dst[i] = __nv_fp8_e4m3(src[i]);
}
__global__ void cast_half(const float *src, __half *dst, long n) {
    long i = (long)blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) dst[i] = __float2half(src[i]);
}

struct Result { const char *mode; double best; double med; int ok; };

static cublasLtHandle_t gLt;

// One cuBLASLt GEMM timing pass. dtypeA == CUDA_R_8F_E4M3 needs scale pointers.
static double time_gemm(int N, int iters,
                        cudaDataType_t inType, cudaDataType_t outType,
                        cublasComputeType_t compute,
                        void *A, void *B, void *C,
                        bool fp8, bool withDScale, float *dScale)
{
    cublasLtMatmulDesc_t op = nullptr;
    LK(cublasLtMatmulDescCreate(&op, compute, outType));
    cublasOperation_t opN = CUBLAS_OP_N;
    LK(cublasLtMatmulDescSetAttribute(op, CUBLASLT_MATMUL_DESC_TRANSA, &opN, sizeof(opN)));
    LK(cublasLtMatmulDescSetAttribute(op, CUBLASLT_MATMUL_DESC_TRANSB, &opN, sizeof(opN)));
    if (fp8) {
        LK(cublasLtMatmulDescSetAttribute(op, CUBLASLT_MATMUL_DESC_A_SCALE_POINTER, &dScale, sizeof(dScale)));
        LK(cublasLtMatmulDescSetAttribute(op, CUBLASLT_MATMUL_DESC_B_SCALE_POINTER, &dScale, sizeof(dScale)));
        if (withDScale)
            LK(cublasLtMatmulDescSetAttribute(op, CUBLASLT_MATMUL_DESC_D_SCALE_POINTER, &dScale, sizeof(dScale)));
    }
    cublasLtMatrixLayout_t Ad=nullptr, Bd=nullptr, Cd=nullptr;
    LK(cublasLtMatrixLayoutCreate(&Ad, inType,  N, N, N));
    LK(cublasLtMatrixLayoutCreate(&Bd, inType,  N, N, N));
    LK(cublasLtMatrixLayoutCreate(&Cd, outType, N, N, N));

    float alpha = 1.0f, beta = 0.0f;

    // FP8 has no default algorithm: ask the library for a concrete one.
    cublasLtMatmulPreference_t pref = nullptr;
    LK(cublasLtMatmulPreferenceCreate(&pref));
    size_t wsBytes = 256ull << 20;
    LK(cublasLtMatmulPreferenceSetAttribute(pref, CUBLASLT_MATMUL_PREF_MAX_WORKSPACE_BYTES,
                                            &wsBytes, sizeof(wsBytes)));
    cublasLtMatmulHeuristicResult_t hr;
    int returned = 0;
    cublasStatus_t hs = cublasLtMatmulAlgoGetHeuristic(gLt, op, Ad, Bd, Cd, Cd, pref, 1, &hr, &returned);
    void *ws = nullptr;
    if (hs != CUBLAS_STATUS_SUCCESS || returned < 1) {
        std::fprintf(stderr, "  no cuBLASLt algorithm for this FP8 layout (status=%d returned=%d)\n",
                     (int)hs, returned);
        LK(cublasLtMatmulPreferenceDestroy(pref));
        LK(cublasLtMatrixLayoutDestroy(Ad));
        LK(cublasLtMatrixLayoutDestroy(Bd));
        LK(cublasLtMatrixLayoutDestroy(Cd));
        LK(cublasLtMatmulDescDestroy(op));
        return -1.0;
    }
    if (hr.workspaceSize) CK(cudaMalloc(&ws, hr.workspaceSize));
    cublasLtMatmulAlgo_t algo = hr.algo;

    for (int i = 0; i < 3; i++)
        LK(cublasLtMatmul(gLt, op, &alpha, A, Ad, B, Bd, &beta, C, Cd, C, Cd,
                          &algo, ws, hr.workspaceSize, nullptr));
    CK(cudaDeviceSynchronize());

    cudaEvent_t t0, t1;
    CK(cudaEventCreate(&t0)); CK(cudaEventCreate(&t1));
    CK(cudaEventRecord(t0));
    for (int i = 0; i < iters; i++)
        LK(cublasLtMatmul(gLt, op, &alpha, A, Ad, B, Bd, &beta, C, Cd, C, Cd,
                          &algo, ws, hr.workspaceSize, nullptr));
    CK(cudaEventRecord(t1));
    CK(cudaEventSynchronize(t1));
    float ms = 0.f;
    CK(cudaEventElapsedTime(&ms, t0, t1));

    if (ws) CK(cudaFree(ws));
    LK(cublasLtMatmulPreferenceDestroy(pref));
    CK(cudaEventDestroy(t0)); CK(cudaEventDestroy(t1));
    LK(cublasLtMatrixLayoutDestroy(Ad));
    LK(cublasLtMatrixLayoutDestroy(Bd));
    LK(cublasLtMatrixLayoutDestroy(Cd));
    LK(cublasLtMatmulDescDestroy(op));

    double secs = (ms / 1000.0) / (double)iters;
    return 2.0 * (double)N * N * N / secs / 1e12;
}

int main(int argc, char **argv)
{
    int N = 4096, iters = 20, reps = 3;
    if (argc > 1) N = std::atoi(argv[1]);
    if (argc > 2) iters = std::atoi(argv[2]);
    if (argc > 3) reps = std::atoi(argv[3]);
    if (N < 256 || iters < 1 || reps < 1) {
        std::fprintf(stderr, "usage: %s [N>=256] [iters>=1] [reps>=1]\n", argv[0]);
        return 2;
    }

    cudaDeviceProp prop;
    CK(cudaGetDeviceProperties(&prop, 0));
    std::printf("# %s, %d SMs, sm_%d%d, N=%d iters=%d reps=%d\n",
                prop.name, prop.multiProcessorCount,
                prop.major, prop.minor, N, iters, reps);

    long elems = (long)N * N;
    size_t bF32 = (size_t)elems * sizeof(float);
    size_t bF8 = (size_t)elems * sizeof(__nv_fp8_e4m3);
    size_t bF16 = (size_t)elems * sizeof(__half);

    std::vector<float> hA(elems), hB(elems);
    std::mt19937 rng(12345);
    std::uniform_real_distribution<float> d(-1.0f, 1.0f);
    for (long i = 0; i < elems; i++) { hA[i] = d(rng); hB[i] = d(rng); }

    void *dA32=nullptr, *dB32=nullptr, *dA8=nullptr, *dB8=nullptr, *dA16=nullptr, *dB16=nullptr, *dC=nullptr;
    CK(cudaMalloc(&dA32, bF32)); CK(cudaMalloc(&dB32, bF32));
    CK(cudaMalloc(&dA8,  bF8));  CK(cudaMalloc(&dB8,  bF8));
    CK(cudaMalloc(&dA16, bF16)); CK(cudaMalloc(&dB16, bF16));
    CK(cudaMalloc(&dC,   bF32));
    CK(cudaMemcpy(dA32, hA.data(), bF32, cudaMemcpyHostToDevice));
    CK(cudaMemcpy(dB32, hB.data(), bF32, cudaMemcpyHostToDevice));

    int block = 256;
    long grid = (elems + block - 1) / block;
    quant_e4m3<<<(int)grid, block>>>((const float*)dA32, (__nv_fp8_e4m3*)dA8, elems);
    quant_e4m3<<<(int)grid, block>>>((const float*)dB32, (__nv_fp8_e4m3*)dB8, elems);
    cast_half <<<(int)grid, block>>>((const float*)dA32, (__half*)dA16, elems);
    cast_half <<<(int)grid, block>>>((const float*)dB32, (__half*)dB16, elems);
    CK(cudaDeviceSynchronize());

    float one = 1.0f;
    float *dScale = nullptr;
    CK(cudaMalloc(&dScale, sizeof(float)));
    CK(cudaMemcpy(dScale, &one, sizeof(float), cudaMemcpyHostToDevice));

    LK(cublasLtCreate(&gLt));

    struct Case { const char *name; cudaDataType_t in, out; cublasComputeType_t comp; void *A,*B; bool fp8; bool dscale; };
    Case cases[] = {
        // FP8 only supports CUBLAS_COMPUTE_32F; D_SCALE is required only for FP8 output.
        { "e4m3_f32", CUDA_R_8F_E4M3, CUDA_R_32F, CUBLAS_COMPUTE_32F, dA8,  dB8,  true,  false },
        { "e4m3_f16", CUDA_R_8F_E4M3, CUDA_R_16F, CUBLAS_COMPUTE_32F, dA8,  dB8,  true,  true  },
        { "fp16_f32", CUDA_R_16F,     CUDA_R_32F, CUBLAS_COMPUTE_32F, dA16, dB16, false, false },
    };

    std::printf("%-10s %12s %12s   runs\n", "mode", "best TF/s", "median TF/s");
    int failures = 0;
    for (auto &c : cases) {
        std::vector<double> s;
        bool unsupported = false;
        for (int r = 0; r < reps; r++) {
            double tf = time_gemm(N, iters, c.in, c.out, c.comp, c.A, c.B, dC, c.fp8, c.dscale, dScale);
            if (tf < 0.0) { unsupported = true; break; }
            s.push_back(tf);
        }
        if (unsupported || s.empty()) {
            std::printf("%-10s %12s %12s   UNSUPPORTED on this layout\n", c.name, "-", "-");
            failures++;
            continue;
        }
        std::sort(s.begin(), s.end());
        double best = s.back();
        double med = s[s.size()/2];
        std::printf("%-10s %12.2f %12.2f   ", c.name, best, med);
        for (size_t i = 0; i < s.size(); i++) std::printf("%s%.1f", i?",":"", s[i]);
        std::printf("\n");
        if (!(best > 0.0)) failures++;
    }

    // numerical sanity: compare e4m3_f32 against an fp32 reference on a corner
    {
        std::printf("\n");
        cublasLtMatmulDesc_t op=nullptr;
        LK(cublasLtMatmulDescCreate(&op, CUBLAS_COMPUTE_32F, CUDA_R_32F));
        cublasOperation_t opN=CUBLAS_OP_N;
        LK(cublasLtMatmulDescSetAttribute(op, CUBLASLT_MATMUL_DESC_TRANSA, &opN, sizeof(opN)));
        LK(cublasLtMatmulDescSetAttribute(op, CUBLASLT_MATMUL_DESC_TRANSB, &opN, sizeof(opN)));
        LK(cublasLtMatmulDescSetAttribute(op, CUBLASLT_MATMUL_DESC_A_SCALE_POINTER, &dScale, sizeof(dScale)));
        LK(cublasLtMatmulDescSetAttribute(op, CUBLASLT_MATMUL_DESC_B_SCALE_POINTER, &dScale, sizeof(dScale)));
        cublasLtMatrixLayout_t Ad=nullptr,Bd=nullptr,Cd=nullptr;
        LK(cublasLtMatrixLayoutCreate(&Ad, CUDA_R_8F_E4M3, N, N, N));
        LK(cublasLtMatrixLayoutCreate(&Bd, CUDA_R_8F_E4M3, N, N, N));
        LK(cublasLtMatrixLayoutCreate(&Cd, CUDA_R_32F, N, N, N));
        float alpha=1.f, beta=0.f;
        LK(cublasLtMatmul(gLt, op, &alpha, dA8, Ad, dB8, Bd, &beta, dC, Cd, dC, Cd, nullptr,nullptr,0,nullptr));
        CK(cudaDeviceSynchronize());

        int m = 64;
        std::vector<float> out(m*m);
        CK(cudaMemcpy(out.data(), dC, (size_t)m*m*sizeof(float), cudaMemcpyDeviceToHost));
        double maxrel = 0.0;
        for (int i = 0; i < m; i++)
            for (int j = 0; j < m; j++) {
                double ref = 0.0;
                for (int k = 0; k < m; k++) {
                    __nv_fp8_e4m3 a(hA[(long)i*N+k]), b(hB[(long)k*N+j]);
                    ref += (float)a * (float)b;
                }
                double got = out[(long)i*m+j];
                double rel = std::fabs(got-ref)/std::max(1.0, std::fabs(ref));
                maxrel = std::max(maxrel, rel);
            }
        std::printf("numerics: e4m3_f32 vs fp32 corner reference, %dx%d, max_rel_err=%.3e %s\n",
                    m, m, maxrel, maxrel < 1e-2 ? "OK" : "CHECK");
        LK(cublasLtMatrixLayoutDestroy(Ad));
        LK(cublasLtMatrixLayoutDestroy(Bd));
        LK(cublasLtMatrixLayoutDestroy(Cd));
        LK(cublasLtMatmulDescDestroy(op));
    }

    cublasLtDestroy(gLt);
    CK(cudaFree(dA32)); CK(cudaFree(dB32)); CK(cudaFree(dA8)); CK(cudaFree(dB8));
    CK(cudaFree(dA16)); CK(cudaFree(dB16)); CK(cudaFree(dC)); CK(cudaFree(dScale));
    return failures ? 1 : 0;
}
