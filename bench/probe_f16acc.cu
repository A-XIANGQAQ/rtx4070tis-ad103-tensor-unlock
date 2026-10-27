// SPDX-License-Identifier: MIT
#include <cuda_runtime.h>
#include <cuda_fp16.h>
#include <cublas_v2.h>
#include <cstdio>
#include <vector>
#include <random>
#define CK(x) do{cudaError_t e_=(x);if(e_!=cudaSuccess){printf("CUDA %s @%d\n",cudaGetErrorString(e_),__LINE__);return 1;}}while(0)
#define BK(x) do{cublasStatus_t s_=(x);if(s_!=CUBLAS_STATUS_SUCCESS){printf("cuBLAS %d @%d\n",(int)s_,__LINE__);return 1;}}while(0)
template<typename T> __global__ void cnz(const T*p,long n,int*o){long i=(long)blockIdx.x*blockDim.x+threadIdx.x;if(i<n&&p[i]!=T(0))atomicAdd(o,1);}
static void gate(const __half*C,long n,int*dev){
  cudaMemset(dev,0,sizeof(int)); long g=(n+255)/256;
  cnz<<<(int)g,256>>>(C,n,dev); cudaDeviceSynchronize();
  int h=0; cudaMemcpy(&h,dev,sizeof(int),cudaMemcpyDeviceToHost);
  printf("   nonzero C: %d / %ld%s\n",h,n,h?"":"   <-- all zeros");
}
int main(int argc,char**argv){
  int *dnz=nullptr; cudaMalloc(&dnz,sizeof(int));
  int N=argc>1?atoi(argv[1]):8192, iters=argc>2?atoi(argv[2]):3;
  long n=(long)N*N; size_t b16=(size_t)n*2;
  __half *A16,*B16,*C16;
  CK(cudaMalloc(&A16,b16)); CK(cudaMalloc(&B16,b16)); CK(cudaMalloc(&C16,b16));
  std::mt19937 rng(7); std::normal_distribution<float> d(0.f,0.05f);
  std::vector<__half> h(n);
  for(long i=0;i<n;i++) h[i]=__float2half(d(rng));
  CK(cudaMemcpy(A16,h.data(),b16,cudaMemcpyHostToDevice));
  for(long i=0;i<n;i++) h[i]=__float2half(d(rng));
  CK(cudaMemcpy(B16,h.data(),b16,cudaMemcpyHostToDevice));
  std::vector<__half>().swap(h);
  cublasHandle_t H; BK(cublasCreate(&H)); BK(cublasSetMathMode(H,CUBLAS_DEFAULT_MATH));

  // variant A: float scale factors (what cublas_gemm.cu does today)
  { float a=1.f,b=0.f;
    BK(cublasGemmEx(H,CUBLAS_OP_N,CUBLAS_OP_N,N,N,N,&a,A16,CUDA_R_16F,N,B16,CUDA_R_16F,N,&b,C16,CUDA_R_16F,N,CUBLAS_COMPUTE_16F,CUBLAS_GEMM_DEFAULT));
    CK(cudaDeviceSynchronize());
    cudaEvent_t t0,t1; CK(cudaEventCreate(&t0)); CK(cudaEventCreate(&t1)); CK(cudaEventRecord(t0));
    for(int i=0;i<iters;i++) BK(cublasGemmEx(H,CUBLAS_OP_N,CUBLAS_OP_N,N,N,N,&a,A16,CUDA_R_16F,N,B16,CUDA_R_16F,N,&b,C16,CUDA_R_16F,N,CUBLAS_COMPUTE_16F,CUBLAS_GEMM_DEFAULT));
    CK(cudaEventRecord(t1)); CK(cudaEventSynchronize(t1));
    float ms=0; CK(cudaEventElapsedTime(&ms,t0,t1));
    printf("float-alpha  (float* as compute16F scales): %8.2f TF/s   (%.3f ms/gemm)\n", 2.0*(double)N*N*N/((ms/1000.0)/iters)/1e12, ms/iters);
    gate(C16,n,dnz);    CK(cudaEventDestroy(t0)); CK(cudaEventDestroy(t1)); }

  // variant B: proper __half scale factors
  { __half a=__float2half(1.f), b=__float2half(0.f);
    BK(cublasGemmEx(H,CUBLAS_OP_N,CUBLAS_OP_N,N,N,N,&a,A16,CUDA_R_16F,N,B16,CUDA_R_16F,N,&b,C16,CUDA_R_16F,N,CUBLAS_COMPUTE_16F,CUBLAS_GEMM_DEFAULT));
    CK(cudaDeviceSynchronize());
    cudaEvent_t t0,t1; CK(cudaEventCreate(&t0)); CK(cudaEventCreate(&t1)); CK(cudaEventRecord(t0));
    for(int i=0;i<iters;i++) BK(cublasGemmEx(H,CUBLAS_OP_N,CUBLAS_OP_N,N,N,N,&a,A16,CUDA_R_16F,N,B16,CUDA_R_16F,N,&b,C16,CUDA_R_16F,N,CUBLAS_COMPUTE_16F,CUBLAS_GEMM_DEFAULT));
    CK(cudaEventRecord(t1)); CK(cudaEventSynchronize(t1));
    float ms=0; CK(cudaEventElapsedTime(&ms,t0,t1));
    printf("half-alpha   (correct compute16F scales)   : %8.2f TF/s   (%.3f ms/gemm)\n", 2.0*(double)N*N*N/((ms/1000.0)/iters)/1e12, ms/iters);
    gate(C16,n,dnz);    CK(cudaEventDestroy(t0)); CK(cudaEventDestroy(t1)); }
  return 0;
}


