// SPDX-License-Identifier: GPL-2.0-only
/*
 * cublas_gemm.cu — end-to-end cuBLAS GEMM throughput, the same instrument the
 * upstream issue #14 (RTX 3070) used to show 44.4 -> 80.2 TF/s.
 *
 * Unlike mma_bench (register-resident issue rate) this measures a real library
 * kernel with memory traffic, so it is what an application actually sees.
 *
 *   fp16/fp32acc   FP16 in, FP32 accumulate  <- unlock target
 *   bf16/fp32acc   BF16 in, FP32 accumulate  <- unlock target
 *   fp16/fp16acc   FP16 in, FP16 accumulate  <- control, must not move
 *   fp32           scalar FP32               <- control, must not move
 *
 * usage: cublas_gemm [N] [iters] [reps]
 */
#include <cuda_runtime.h>
#include <cuda_fp16.h>
#include <cuda_bf16.h>
#include <cublas_v2.h>
#include <cstdio>
#include <cstdlib>
#include <vector>
#include <random>
#include <algorithm>

#define CK(x) do{ cudaError_t e_=(x); if(e_!=cudaSuccess){ \
  std::fprintf(stderr,"CUDA %s (%d)\n",cudaGetErrorString(e_),__LINE__); std::exit(1);} }while(0)
#define BK(x) do{ cublasStatus_t s_=(x); if(s_!=CUBLAS_STATUS_SUCCESS){ \
  std::fprintf(stderr,"cuBLAS status %d (%d)\n",(int)s_,__LINE__); std::exit(1);} }while(0)

__global__ void f32_to_h(const float *src, __half *dst, long n){
    long i=(long)blockIdx.x*blockDim.x+threadIdx.x; if(i<n) dst[i]=__float2half(src[i]); }
__global__ void f32_to_b(const float *src, __nv_bfloat16 *dst, long n){
    long i=(long)blockIdx.x*blockDim.x+threadIdx.x; if(i<n) dst[i]=__float2bfloat16(src[i]); }

static cublasHandle_t H;
static cublasComputeType_t gCompute;
static cudaDataType_t gIn, gOut;

static double run(int N,int iters,void *A,void *B,void *C){
    float alpha=1.f,beta=0.f;
    BK(cublasGemmEx(H,CUBLAS_OP_N,CUBLAS_OP_N,N,N,N,
                    &alpha,A,gIn,N,B,gIn,N,&beta,C,gOut,N,
                    gCompute,CUBLAS_GEMM_DEFAULT));
    CK(cudaDeviceSynchronize());
    cudaEvent_t t0,t1; CK(cudaEventCreate(&t0)); CK(cudaEventCreate(&t1));
    CK(cudaEventRecord(t0));
    for(int i=0;i<iters;i++)
        BK(cublasGemmEx(H,CUBLAS_OP_N,CUBLAS_OP_N,N,N,N,
                        &alpha,A,gIn,N,B,gIn,N,&beta,C,gOut,N,
                        gCompute,CUBLAS_GEMM_DEFAULT));
    CK(cudaEventRecord(t1)); CK(cudaEventSynchronize(t1));
    float ms=0.f; CK(cudaEventElapsedTime(&ms,t0,t1));
    CK(cudaEventDestroy(t0)); CK(cudaEventDestroy(t1));
    return 2.0*(double)N*N*N/((ms/1000.0)/iters)/1e12;
}

int main(int argc,char **argv){
    int N=8192, iters=3, reps=3;
    if(argc>1) N=std::atoi(argv[1]);
    if(argc>2) iters=std::atoi(argv[2]);
    if(argc>3) reps=std::atoi(argv[3]);
    if(N<256||iters<1||reps<1){ std::fprintf(stderr,"usage: %s [N] [iters] [reps]\n",argv[0]); return 2; }

    cudaDeviceProp p; CK(cudaGetDeviceProperties(&p,0));
    std::printf("# %s, %d SMs, sm_%d%d, N=%d iters=%d reps=%d\n",
                p.name,p.multiProcessorCount,p.major,p.minor,N,iters,reps);
    double memGB = 3.0*(double)N*N*4.0/1e9;
    std::printf("# working set ~%.2f GB (f32 staging + 2 inputs)\n", memGB);

    long n=(long)N*N;
    size_t bf32=(size_t)n*sizeof(float), bf16=(size_t)n*2;
    std::vector<float> hA(n),hB(n);
    std::mt19937 rng(7);
    std::normal_distribution<float> d(0.f,0.05f);
    for(long i=0;i<n;i++){ hA[i]=d(rng); hB[i]=d(rng); }

    void *A32=nullptr,*B32=nullptr,*A16=nullptr,*B16=nullptr,*C32=nullptr,*C16=nullptr;
    CK(cudaMalloc(&A32,bf32)); CK(cudaMalloc(&B32,bf32));
    CK(cudaMalloc(&A16,bf16)); CK(cudaMalloc(&B16,bf16));
    CK(cudaMalloc(&C32,bf32)); CK(cudaMalloc(&C16,bf16));
    CK(cudaMemcpy(A32,hA.data(),bf32,cudaMemcpyHostToDevice));
    CK(cudaMemcpy(B32,hB.data(),bf32,cudaMemcpyHostToDevice));
    std::vector<float>().swap(hA); std::vector<float>().swap(hB);

    int blk=256; long grd=(n+blk-1)/blk;
    f32_to_h<<<(int)grd,blk>>>((const float*)A32,(__half*)A16,n);
    f32_to_h<<<(int)grd,blk>>>((const float*)B32,(__half*)B16,n);
    CK(cudaDeviceSynchronize());

    BK(cublasCreate(&H));
    BK(cublasSetMathMode(H,CUBLAS_DEFAULT_MATH));

    struct Case{ const char *name; cublasComputeType_t comp; cudaDataType_t in,out; void *A,*B,*C; };
    Case cases[]={
        {"fp16/fp32acc", CUBLAS_COMPUTE_32F, CUDA_R_16F, CUDA_R_32F, A16,B16,C32},
        {"fp16/fp16acc", CUBLAS_COMPUTE_16F, CUDA_R_16F, CUDA_R_16F, A16,B16,C16},
        {"fp32",         CUBLAS_COMPUTE_32F, CUDA_R_32F, CUDA_R_32F, A32,B32,C32},
    };

    std::printf("%-14s %12s %12s   runs\n","mode","best TF/s","median TF/s");
    for(auto &c:cases){
        gCompute=c.comp; gIn=c.in; gOut=c.out;
        std::vector<double> s;
        for(int r=0;r<reps;r++) s.push_back(run(N,iters,c.A,c.B,c.C));
        std::sort(s.begin(),s.end());
        std::printf("%-14s %12.2f %12.2f   ",c.name,s.back(),s[s.size()/2]);
        for(size_t i=0;i<s.size();i++) std::printf("%s%.1f",i?"/":"",s[i]);
        std::printf("\n");
        CK(cudaDeviceSynchronize());
        cudaError_t e=cudaGetLastError();
        if(e!=cudaSuccess) std::printf("   (kernel error: %s)\n",cudaGetErrorString(e));
    }

    // bf16 pass (separate because it needs its own conversion)
    void *Ab=nullptr,*Bb=nullptr;
    CK(cudaMalloc(&Ab,bf16)); CK(cudaMalloc(&Bb,bf16));
    f32_to_b<<<(int)grd,blk>>>((const float*)A32,(__nv_bfloat16*)Ab,n);
    f32_to_b<<<(int)grd,blk>>>((const float*)B32,(__nv_bfloat16*)Bb,n);
    CK(cudaDeviceSynchronize());
    gCompute=CUBLAS_COMPUTE_32F; gIn=CUDA_R_16BF; gOut=CUDA_R_32F;
    std::vector<double> s;
    for(int r=0;r<reps;r++) s.push_back(run(N,iters,Ab,Bb,C32));
    std::sort(s.begin(),s.end());
    std::printf("%-14s %12.2f %12.2f   ","bf16/fp32acc",s.back(),s[s.size()/2]);
    for(size_t i=0;i<s.size();i++) std::printf("%s%.1f",i?"/":"",s[i]);
    std::printf("\n");

    BK(cublasDestroy(H));
    CK(cudaFree(A32)); CK(cudaFree(B32)); CK(cudaFree(A16)); CK(cudaFree(B16));
    CK(cudaFree(C32)); CK(cudaFree(C16)); CK(cudaFree(Ab)); CK(cudaFree(Bb));
    return 0;
}
