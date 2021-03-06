/*
    Copyright 2017 Zheyong Fan, Ville Vierimaa, Mikko Ervasti, and Ari Harju
    This file is part of GPUMD.
    GPUMD is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.
    GPUMD is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.
    You should have received a copy of the GNU General Public License
    along with GPUMD.  If not, see <http://www.gnu.org/licenses/>.
*/




#include "common.cuh"
#include "hnemd_kappa.cuh"
#include "integrate.cuh"
#include "ensemble.cuh"
#define NUM_OF_HEAT_COMPONENTS 5




static __device__ void warp_reduce(volatile real *s, int t) 
{
    s[t] += s[t + 32]; s[t] += s[t + 16]; s[t] += s[t + 8];
    s[t] += s[t + 4];  s[t] += s[t + 2];  s[t] += s[t + 1];
}




void preprocess_hnemd_kappa
(Parameters *para, CPU_Data *cpu_data, GPU_Data *gpu_data)
{
    if (para->hnemd.compute)
    {
        int num = NUM_OF_HEAT_COMPONENTS * para->hnemd.output_interval;
        CHECK(cudaMalloc((void**)&gpu_data->heat_all, sizeof(real) * num));
    }
}




static __global__ void gpu_sum_heat
(int N, int step, real *g_heat, real *g_heat_sum)
{
    // <<<5, 1024>>> 
    int tid = threadIdx.x; 
    int bid = blockIdx.x;
    int number_of_patches = (N - 1) / 1024 + 1;
    __shared__ real s_data[1024];  
    s_data[tid] = ZERO;
    for (int patch = 0; patch < number_of_patches; ++patch)
    {
        int n = tid + patch * 1024; 
        if (n < N) { s_data[tid] += g_heat[n + N * bid]; }
    }
    __syncthreads();
    if (tid < 512) { s_data[tid] += s_data[tid + 512]; } __syncthreads();
    if (tid < 256) { s_data[tid] += s_data[tid + 256]; } __syncthreads();
    if (tid < 128) { s_data[tid] += s_data[tid + 128]; } __syncthreads();
    if (tid <  64) { s_data[tid] += s_data[tid +  64]; } __syncthreads();
    if (tid <  32) { warp_reduce(s_data, tid);         } 
    if (tid ==  0) { g_heat_sum[step*NUM_OF_HEAT_COMPONENTS+bid] = s_data[0]; }
}




static real get_volume(real *box_gpu)
{
    real *box_cpu;
    MY_MALLOC(box_cpu, real, 3);
    cudaMemcpy(box_cpu, box_gpu, sizeof(real) * 3, cudaMemcpyDeviceToHost);
    real volume = box_cpu[0] * box_cpu[1] * box_cpu[2];
    MY_FREE(box_cpu);
    return volume;
}




void process_hnemd_kappa
(
    int step, char *input_dir, Parameters *para, 
    CPU_Data *cpu_data, GPU_Data *gpu_data, Integrate *integrate
)
{
    if (para->hnemd.compute)
    {
        int output_flag = ((step+1) % para->hnemd.output_interval == 0);
        step %= para->hnemd.output_interval;
        gpu_sum_heat<<<5, 1024>>>
        (para->N, step, gpu_data->heat_per_atom, gpu_data->heat_all);
        if (output_flag)
        {
            int num = NUM_OF_HEAT_COMPONENTS * para->hnemd.output_interval;
            int mem = sizeof(real) * num;
            real volume = get_volume(gpu_data->box_length);
            real *heat_cpu;
            MY_MALLOC(heat_cpu, real, num);
            cudaMemcpy
            (heat_cpu, gpu_data->heat_all, mem, cudaMemcpyDeviceToHost);
            real kappa[NUM_OF_HEAT_COMPONENTS];
            for (int n = 0; n < NUM_OF_HEAT_COMPONENTS; n++) 
            {
                kappa[n] = ZERO;
            }
            for (int m = 0; m < para->hnemd.output_interval; m++)
            {
                for (int n = 0; n < NUM_OF_HEAT_COMPONENTS; n++)
                {
                    kappa[n] += heat_cpu[m * NUM_OF_HEAT_COMPONENTS + n];
                }
            }
            real factor = KAPPA_UNIT_CONVERSION / para->hnemd.output_interval;
            factor /= (volume * integrate->ensemble->temperature * para->hnemd.fe);

            char file_kappa[FILE_NAME_LENGTH];
            strcpy(file_kappa, input_dir);
            strcat(file_kappa, "/kappa.out");
            FILE *fid = fopen(file_kappa, "a");
            for (int n = 0; n < NUM_OF_HEAT_COMPONENTS; n++)
            {
                fprintf(fid, "%25.15f", kappa[n] * factor);
            }
            fprintf(fid, "\n");
            fflush(fid);  
            fclose(fid);
            MY_FREE(heat_cpu);
        }
    }
}





void postprocess_hnemd_kappa
(Parameters *para, CPU_Data *cpu_data, GPU_Data *gpu_data)
{
    if (para->hnemd.compute) { cudaFree(gpu_data->heat_all); }
}




