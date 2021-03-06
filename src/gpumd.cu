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
#include "gpumd.cuh"
#include "force.cuh"
#include "validate.cuh"
#include "integrate.cuh"
#include "ensemble.cuh" 
#include "measure.cuh"
#include "parse.cuh" 
#include "velocity.cuh"
#include "neighbor.cuh"




GPUMD::GPUMD(char *input_dir)
{ 
    // Data structures:
    Parameters  para;
    CPU_Data    cpu_data;
    GPU_Data    gpu_data;
    Force       force;
    Integrate   integrate;
    Measure     measure(input_dir);

    initialize(input_dir, &para, &cpu_data, &gpu_data);
    run(input_dir, &para, &cpu_data, &gpu_data, &force, &integrate, &measure);
    finalize(&cpu_data, &gpu_data);
}




GPUMD::~GPUMD(void)
{
    // nothing
} 




static void initialize_position
(char *input_dir, Parameters *para, CPU_Data *cpu_data)
{  
    printf("---------------------------------------------------------------\n");
    printf("INFO:  read in initial positions and related parameters.\n");

    int count = 0;
    char file_xyz[FILE_NAME_LENGTH];
    strcpy(file_xyz, input_dir);
    strcat(file_xyz, "/xyz.in");
    FILE *fid_xyz = my_fopen(file_xyz, "r"); 

    // the first line of the xyz.in file
    double rc;
    count = fscanf(fid_xyz, "%d%d%lf", &para->N, &para->neighbor.MN, &rc);
    if (count != 3) print_error("reading error for line 1 of xyz.in.\n");
    para->neighbor.rc = rc;
    if (para->N < 1)
        print_error("number of atoms should >= 1\n");
    else
        printf("INPUT: number of atoms is %d.\n", para->N);
    
    if (para->neighbor.MN < 0)
        print_error("maximum number of neighbors should >= 0\n");
    else
        printf("INPUT: maximum number of neighbors is %d.\n",para->neighbor.MN);

    if (para->neighbor.rc < 0)
        print_error("initial cutoff for neighbor list should >= 0\n");
    else
        printf
        (
            "INPUT: initial cutoff for neighbor list is %g A.\n", 
            para->neighbor.rc
        );    

    // now we have enough information to allocate memroy for the major data
    MY_MALLOC(cpu_data->NN,         int, para->N);
    MY_MALLOC(cpu_data->NL,         int, para->N * para->neighbor.MN);
    MY_MALLOC(cpu_data->type,       int, para->N);
    MY_MALLOC(cpu_data->type_local, int, para->N);
    MY_MALLOC(cpu_data->label,      int, para->N);
    MY_MALLOC(cpu_data->mass, real, para->N);
    MY_MALLOC(cpu_data->x,    real, para->N);
    MY_MALLOC(cpu_data->y,    real, para->N);
    MY_MALLOC(cpu_data->z,    real, para->N);
    MY_MALLOC(cpu_data->vx,   real, para->N);
    MY_MALLOC(cpu_data->vy,   real, para->N);
    MY_MALLOC(cpu_data->vz,   real, para->N);
    MY_MALLOC(cpu_data->fx,   real, para->N);
    MY_MALLOC(cpu_data->fy,   real, para->N);
    MY_MALLOC(cpu_data->fz,   real, para->N);
    MY_MALLOC(cpu_data->heat_per_atom, real, para->N * NUM_OF_HEAT_COMPONENTS);
    MY_MALLOC(cpu_data->thermo, real, 6);
    MY_MALLOC(cpu_data->box_length, real, 3);
    MY_MALLOC(cpu_data->box_matrix, real, 9);
    MY_MALLOC(cpu_data->box_matrix_inv, real, 9);

#ifdef TRICLINIC

    // second line: boundary conditions
    count = fscanf
    (fid_xyz, "%d%d%d", &(para->pbc_x), &(para->pbc_y), &(para->pbc_z));
    if (count != 3) print_error("reading error for line 2 of xyz.in.\n");

    // third line: triclinic box parameters
    double box[9];   
    count = fscanf
    (
        fid_xyz, "%lf%lf%lf%lf%lf%lf%lf%lf%lf", &box[0], &box[1], &box[2], 
        &box[3], &box[4], &box[5], &box[6], &box[7], &box[8]
    ); 
    if (count != 9) print_error("reading error for line 3 of xyz.in.\n");
    for (int n = 0; n < 9; ++n) cpu_data->box_matrix[n] = box[n];

    real volume = cpu_data->box_matrix[0]
                * cpu_data->box_matrix[4]
                * cpu_data->box_matrix[8] 
                + cpu_data->box_matrix[1]
                * cpu_data->box_matrix[5]
                * cpu_data->box_matrix[6] 
                + cpu_data->box_matrix[2]
                * cpu_data->box_matrix[3]
                * cpu_data->box_matrix[7]
                - cpu_data->box_matrix[2]
                * cpu_data->box_matrix[4]
                * cpu_data->box_matrix[6] 
                - cpu_data->box_matrix[1]
                * cpu_data->box_matrix[3]
                * cpu_data->box_matrix[8] 
                - cpu_data->box_matrix[0]
                * cpu_data->box_matrix[5]
                * cpu_data->box_matrix[7];

    cpu_data->box_matrix_inv[0] = cpu_data->box_matrix[4]
                                * cpu_data->box_matrix[8] 
                                - cpu_data->box_matrix[5]
                                * cpu_data->box_matrix[7];
    cpu_data->box_matrix_inv[1] = cpu_data->box_matrix[2]
                                * cpu_data->box_matrix[7] 
                                - cpu_data->box_matrix[1]
                                * cpu_data->box_matrix[8];
    cpu_data->box_matrix_inv[2] = cpu_data->box_matrix[1]
                                * cpu_data->box_matrix[5] 
                                - cpu_data->box_matrix[2]
                                * cpu_data->box_matrix[4];
    cpu_data->box_matrix_inv[3] = cpu_data->box_matrix[5]
                                * cpu_data->box_matrix[6] 
                                - cpu_data->box_matrix[3]
                                * cpu_data->box_matrix[8];
    cpu_data->box_matrix_inv[4] = cpu_data->box_matrix[0]
                                * cpu_data->box_matrix[8] 
                                - cpu_data->box_matrix[2]
                                * cpu_data->box_matrix[6];
    cpu_data->box_matrix_inv[5] = cpu_data->box_matrix[2]
                                * cpu_data->box_matrix[3] 
                                - cpu_data->box_matrix[0]
                                * cpu_data->box_matrix[5];
    cpu_data->box_matrix_inv[6] = cpu_data->box_matrix[3]
                                * cpu_data->box_matrix[7] 
                                - cpu_data->box_matrix[4]
                                * cpu_data->box_matrix[6];
    cpu_data->box_matrix_inv[7] = cpu_data->box_matrix[1]
                                * cpu_data->box_matrix[6] 
                                - cpu_data->box_matrix[0]
                                * cpu_data->box_matrix[7];
    cpu_data->box_matrix_inv[8] = cpu_data->box_matrix[0]
                                * cpu_data->box_matrix[4] 
                                - cpu_data->box_matrix[1]
                                * cpu_data->box_matrix[3];

    for (int n = 0; n < 9; n++) cpu_data->box_matrix_inv[n] /= volume;

#else // #ifdef TRICLINIC

    // the second line of the xyz.in file (boundary conditions and box size)
    double lx, ly, lz;
    count = fscanf
    (
        fid_xyz, "%d%d%d%lf%lf%lf", 
        &(para->pbc_x), &(para->pbc_y), &(para->pbc_z), &lx, &ly, &lz
    );
    if (count != 6) print_error("reading error for line 2 of xyz.in.\n");
    cpu_data->box_length[0] = lx;
    cpu_data->box_length[1] = ly;
    cpu_data->box_length[2] = lz;

#endif // #ifdef TRICLINIC

    if (para->pbc_x == 1)
        printf("INPUT: use periodic boundary conditions along x.\n");
    else if (para->pbc_x == 0)
        printf("INPUT: use     free boundary conditions along x.\n");
    else
        print_error("invalid boundary conditions along x.\n");

    if (para->pbc_y == 1)
        printf("INPUT: use periodic boundary conditions along y.\n");
    else if (para->pbc_y == 0)
        printf("INPUT: use     free boundary conditions along y.\n");
    else
        print_error("invalid boundary conditions along y.\n");

    if (para->pbc_z == 1)
        printf("INPUT: use periodic boundary conditions along z.\n");
    else if (para->pbc_z == 0)
        printf("INPUT: use     free boundary conditions along z.\n");
    else
        print_error("invalid boundary conditions along z.\n");

    // the remaining lines in the xyz.in file (type, label, mass, and positions)
    int max_label = -1; // used to determine the number of groups
    int max_type = -1; // used to determine the number of types
    for (int n = 0; n < para->N; n++) 
    {
        double mass, x, y, z;
        count = fscanf
        (
            fid_xyz, "%d%d%lf%lf%lf%lf", 
            &(cpu_data->type[n]), &(cpu_data->label[n]), &mass, &x, &y, &z
        );
        if (count != 6) print_error("reading error for xyz.in.\n");
        cpu_data->mass[n] = mass;
        cpu_data->x[n] = x;
        cpu_data->y[n] = y;
        cpu_data->z[n] = z;

        if (cpu_data->label[n] > max_label)
            max_label = cpu_data->label[n];

        if (cpu_data->type[n] > max_type)
            max_type = cpu_data->type[n];

        // copy
        cpu_data->type_local[n] = cpu_data->type[n];
    }

    fclose(fid_xyz);

    // number of groups determined
    para->number_of_groups = max_label + 1;
    if (para->number_of_groups == 1)
        printf("INPUT: there is only one group of atoms.\n");
    else
        printf("INPUT: there are %d groups of atoms.\n",para->number_of_groups);

    // determine the number of atoms in each group
    MY_MALLOC(cpu_data->group_size, int, para->number_of_groups);
    MY_MALLOC(cpu_data->group_size_sum, int, para->number_of_groups);
    for (int m = 0; m < para->number_of_groups; m++)
    {
        cpu_data->group_size[m] = 0;
        cpu_data->group_size_sum[m] = 0;
    }
    for (int n = 0; n < para->N; n++) 
        cpu_data->group_size[cpu_data->label[n]]++;
    for (int m = 0; m < para->number_of_groups; m++)
        printf("       %d atoms in group %d.\n", cpu_data->group_size[m], m);   
    
    // calculate the number of atoms before a group
    for (int m = 1; m < para->number_of_groups; m++)
        for (int n = 0; n < m; n++)
            cpu_data->group_size_sum[m] += cpu_data->group_size[n];

    // determine the atom indices from the first to the last group
    MY_MALLOC(cpu_data->group_contents, int, para->N);
    int *offset;
    MY_MALLOC(offset, int, para->number_of_groups);
    for (int m = 0; m < para->number_of_groups; m++) offset[m] = 0;
    for (int n = 0; n < para->N; n++) 
        for (int m = 0; m < para->number_of_groups; m++)
            if (cpu_data->label[n] == m)
            {
                cpu_data->group_contents[cpu_data->group_size_sum[m]+offset[m]] 
                    = n;
                offset[m]++;
            }
    MY_FREE(offset);

    // number of types determined
    para->number_of_types = max_type + 1;
    if (para->number_of_types == 1)
        printf("INPUT: there is only one atom type.\n");
    else
        printf("INPUT: there are %d atom types.\n", para->number_of_types);

    // determine the number of atoms in each type
    MY_MALLOC(cpu_data->type_size, int, para->number_of_types);
    for (int m = 0; m < para->number_of_types; m++)
        cpu_data->type_size[m] = 0;
    for (int n = 0; n < para->N; n++) 
        cpu_data->type_size[cpu_data->type[n]]++;
    for (int m = 0; m < para->number_of_types; m++)
        printf("       %d atoms of type %d.\n", cpu_data->type_size[m], m); 

    printf("INFO:  positions and related parameters initialized.\n");
    printf("---------------------------------------------------------------\n");
    printf("\n");
}




static void allocate_memory_gpu(Parameters *para, GPU_Data *gpu_data)
{
    // memory amount
    int m1 = sizeof(int) * para->N;
    int m2 = m1 * para->neighbor.MN;
    int m3 = sizeof(int) * para->number_of_groups;
    int m4 = sizeof(real) * para->N;
    int m5 = m4 * NUM_OF_HEAT_COMPONENTS;

    // for indexing
    CHECK(cudaMalloc((void**)&gpu_data->NN, m1)); 
    CHECK(cudaMalloc((void**)&gpu_data->NL, m2)); 
#ifndef FIXED_NL
    CHECK(cudaMalloc((void**)&gpu_data->NN_local, m1)); 
    CHECK(cudaMalloc((void**)&gpu_data->NL_local, m2));
#endif
    CHECK(cudaMalloc((void**)&gpu_data->type, m1));  
    CHECK(cudaMalloc((void**)&gpu_data->type_local, m1));
    CHECK(cudaMalloc((void**)&gpu_data->label, m1)); 
    CHECK(cudaMalloc((void**)&gpu_data->group_size, m3)); 
    CHECK(cudaMalloc((void**)&gpu_data->group_size_sum, m3));
    CHECK(cudaMalloc((void**)&gpu_data->group_contents, m1));

    // for atoms
    CHECK(cudaMalloc((void**)&gpu_data->mass, m4));
    CHECK(cudaMalloc((void**)&gpu_data->x0,   m4));
    CHECK(cudaMalloc((void**)&gpu_data->y0,   m4));
    CHECK(cudaMalloc((void**)&gpu_data->z0,   m4));
    CHECK(cudaMalloc((void**)&gpu_data->x,    m4));
    CHECK(cudaMalloc((void**)&gpu_data->y,    m4));
    CHECK(cudaMalloc((void**)&gpu_data->z,    m4));
    CHECK(cudaMalloc((void**)&gpu_data->vx,   m4));
    CHECK(cudaMalloc((void**)&gpu_data->vy,   m4));
    CHECK(cudaMalloc((void**)&gpu_data->vz,   m4));
    CHECK(cudaMalloc((void**)&gpu_data->fx,   m4));
    CHECK(cudaMalloc((void**)&gpu_data->fy,   m4));
    CHECK(cudaMalloc((void**)&gpu_data->fz,   m4));

    CHECK(cudaMalloc((void**)&gpu_data->heat_per_atom, m5));

    // per-atom stress and potential energy, which are always needed
    CHECK(cudaMalloc((void**)&gpu_data->virial_per_atom_x,  m4));
    CHECK(cudaMalloc((void**)&gpu_data->virial_per_atom_y,  m4));
    CHECK(cudaMalloc((void**)&gpu_data->virial_per_atom_z,  m4));
    CHECK(cudaMalloc((void**)&gpu_data->potential_per_atom, m4));

    // box lengths
    CHECK(cudaMalloc((void**)&gpu_data->box_matrix,     sizeof(real) * 9));
    CHECK(cudaMalloc((void**)&gpu_data->box_matrix_inv, sizeof(real) * 9));
    CHECK(cudaMalloc((void**)&gpu_data->box_length, sizeof(real) * DIM));

    // 6 thermodynamic quantities
    CHECK(cudaMalloc((void**)&gpu_data->thermo, sizeof(real) * 6));

}




static void copy_from_cpu_to_gpu
(Parameters *para, CPU_Data *cpu_data, GPU_Data *gpu_data)
{
    int m1 = sizeof(int) * para->N;
    int m2 = sizeof(int) * para->number_of_groups;
    int m3 = sizeof(real) * para->N;
    int m4 = sizeof(real) * DIM;

    cudaMemcpy(gpu_data->type, cpu_data->type, m1, cudaMemcpyHostToDevice); 
    cudaMemcpy
    (gpu_data->type_local, cpu_data->type, m1, cudaMemcpyHostToDevice);
    cudaMemcpy(gpu_data->label, cpu_data->label, m1, cudaMemcpyHostToDevice); 

    cudaMemcpy
    (gpu_data->group_size, cpu_data->group_size, m2, cudaMemcpyHostToDevice);
    cudaMemcpy
    (
        gpu_data->group_size_sum, cpu_data->group_size_sum, m2, 
        cudaMemcpyHostToDevice
    );
    cudaMemcpy
    (
        gpu_data->group_contents, cpu_data->group_contents, m1, 
        cudaMemcpyHostToDevice
    );

    cudaMemcpy(gpu_data->mass, cpu_data->mass, m3, cudaMemcpyHostToDevice);
    cudaMemcpy(gpu_data->x, cpu_data->x, m3, cudaMemcpyHostToDevice); 
    cudaMemcpy(gpu_data->y, cpu_data->y, m3, cudaMemcpyHostToDevice); 
    cudaMemcpy(gpu_data->z, cpu_data->z, m3, cudaMemcpyHostToDevice);

    cudaMemcpy
    (
        gpu_data->box_matrix, cpu_data->box_matrix, 
        9 * sizeof(real), cudaMemcpyHostToDevice
    );
    cudaMemcpy
    (
        gpu_data->box_matrix_inv, cpu_data->box_matrix_inv, 
        9 * sizeof(real), cudaMemcpyHostToDevice
    );
    cudaMemcpy
    (gpu_data->box_length, cpu_data->box_length, m4, cudaMemcpyHostToDevice);
}




void GPUMD::initialize
(char *input_dir, Parameters *para, CPU_Data *cpu_data, GPU_Data *gpu_data)
{ 
    initialize_position(input_dir, para, cpu_data);
    allocate_memory_gpu(para, gpu_data);
    copy_from_cpu_to_gpu(para, cpu_data, gpu_data);

    // build the initial neighbor list
    int is_first = 1;
    find_neighbor(para, cpu_data, gpu_data, is_first);
}




void GPUMD::finalize(CPU_Data *cpu_data, GPU_Data *gpu_data)
{
    // Free the memory allocated on the GPU
    CHECK(cudaFree(gpu_data->NN)); 
    CHECK(cudaFree(gpu_data->NL)); 
    CHECK(cudaFree(gpu_data->NN_local)); 
    CHECK(cudaFree(gpu_data->NL_local));
    CHECK(cudaFree(gpu_data->type));  
    CHECK(cudaFree(gpu_data->type_local));
    CHECK(cudaFree(gpu_data->label)); 
    CHECK(cudaFree(gpu_data->group_size)); 
    CHECK(cudaFree(gpu_data->group_size_sum));
    CHECK(cudaFree(gpu_data->group_contents));
    CHECK(cudaFree(gpu_data->mass));
    CHECK(cudaFree(gpu_data->x0));  
    CHECK(cudaFree(gpu_data->y0));  
    CHECK(cudaFree(gpu_data->z0));
    CHECK(cudaFree(gpu_data->x));  
    CHECK(cudaFree(gpu_data->y));  
    CHECK(cudaFree(gpu_data->z));
    CHECK(cudaFree(gpu_data->vx)); 
    CHECK(cudaFree(gpu_data->vy)); 
    CHECK(cudaFree(gpu_data->vz));
    CHECK(cudaFree(gpu_data->fx)); 
    CHECK(cudaFree(gpu_data->fy)); 
    CHECK(cudaFree(gpu_data->fz));
    CHECK(cudaFree(gpu_data->virial_per_atom_x));
    CHECK(cudaFree(gpu_data->virial_per_atom_y));
    CHECK(cudaFree(gpu_data->virial_per_atom_z));
    CHECK(cudaFree(gpu_data->potential_per_atom));
    CHECK(cudaFree(gpu_data->heat_per_atom));    
    //#ifdef TRICLINIC
    CHECK(cudaFree(gpu_data->box_matrix));
    CHECK(cudaFree(gpu_data->box_matrix_inv));
    //#else
    CHECK(cudaFree(gpu_data->box_length));
    //#endif
    CHECK(cudaFree(gpu_data->thermo));

    // Free the major memory allocated on the CPU
    MY_FREE(cpu_data->NN);
    MY_FREE(cpu_data->NL);
    MY_FREE(cpu_data->type);
    MY_FREE(cpu_data->type_local);
    MY_FREE(cpu_data->label);
    MY_FREE(cpu_data->group_size);
    MY_FREE(cpu_data->group_size_sum);
    MY_FREE(cpu_data->group_contents);
    MY_FREE(cpu_data->type_size);
    MY_FREE(cpu_data->mass);
    MY_FREE(cpu_data->x);
    MY_FREE(cpu_data->y);
    MY_FREE(cpu_data->z);
    MY_FREE(cpu_data->vx);
    MY_FREE(cpu_data->vy);
    MY_FREE(cpu_data->vz);
    MY_FREE(cpu_data->fx);
    MY_FREE(cpu_data->fy);
    MY_FREE(cpu_data->fz);  
    MY_FREE(cpu_data->heat_per_atom);
    MY_FREE(cpu_data->thermo);
    MY_FREE(cpu_data->box_length);
    MY_FREE(cpu_data->box_matrix);
    MY_FREE(cpu_data->box_matrix_inv);
}




/*----------------------------------------------------------------------------80
    run a number of steps for a given set of inputs
------------------------------------------------------------------------------*/
static void process_run 
(
    char **param, 
    unsigned int num_param, 
    char *input_dir,  
    Parameters *para, 
    CPU_Data *cpu_data,
    GPU_Data *gpu_data,
    Force *force,
    Integrate *integrate,
    Measure *measure
)
{
    integrate->initialize(para, cpu_data); 
    measure->initialize(para, cpu_data, gpu_data);

    // record the starting time for this run
    clock_t time_begin = clock();

    // Now, start to run!
    for (int step = 0; step < para->number_of_steps; ++step)
    {  
        // update the neighbor list
        if (para->neighbor.update)
        {
            find_neighbor(para, cpu_data, gpu_data, 0);
        }

        // set the current temperature;
        if (integrate->ensemble->type >= 1 && integrate->ensemble->type <= 3)
        {
            integrate->ensemble->temperature = para->temperature1 
                + (para->temperature2 - para->temperature1)
                * real(step) / para->number_of_steps;   
        }

        // integrate by one time-step:
        integrate->compute(para, cpu_data, gpu_data, force);

        // measure
        measure->compute(input_dir, para, cpu_data, gpu_data, integrate, step);

        if (para->number_of_steps >= 10)
        {
            if ((step + 1) % (para->number_of_steps / 10) == 0)
            {
                printf("INFO:  %d steps completed.\n", step + 1);
            }
        }
    }
    
    // only for myself
    if (0)
    {
        validate_force(force, para, cpu_data, gpu_data);
    }

    printf("INFO:  This run is completed.\n\n");

    // report the time used for this run and its speed:
    clock_t time_finish = clock();
    real time_used = (time_finish - time_begin) / (real) CLOCKS_PER_SEC;
    printf("INFO:  Time used for this run = %g s.\n", time_used);
    real run_speed = para->N * (para->number_of_steps / time_used);
    printf("INFO:  Speed of this run = %g atom*step/second.\n\n", run_speed);

    measure->finalize(input_dir, para, cpu_data, gpu_data, integrate);
    integrate->finalize();
}




/*----------------------------------------------------------------------------80
    set some default values after each run
------------------------------------------------------------------------------*/
static void initialize_run(Parameters *para)
{
    para->neighbor.update = 0;
    para->heat.sample     = 0;
    para->shc.compute     = 0;
    para->vac.compute     = 0; 
    para->hac.compute     = 0; 
    para->hnemd.compute   = 0;
    para->strain.compute  = 0; 
    para->fixed_group     = -1; // no group has an index of -1
}




/*----------------------------------------------------------------------------80
	Read the input file to memory in the beginning, because
	we do not want to keep the FILE handle open all the time
------------------------------------------------------------------------------*/
static char *get_file_contents (char *filename)
{

    char *contents;
    int contents_size;
    FILE *in = my_fopen(filename, "r");

    // Find file size
    fseek(in, 0, SEEK_END);
    contents_size = ftell(in);
    rewind(in);

    MY_MALLOC(contents, char, contents_size + 1);
    int size_read_in = fread(contents, sizeof(char), contents_size, in);
    if (size_read_in != contents_size)
    {
        print_error ("File size mismatch.");
    }

    fclose(in);
    contents[contents_size] = '\0'; // Assures proper null termination

    return contents;
}




/*----------------------------------------------------------------------------80
	Parse a single row
------------------------------------------------------------------------------*/
static char *row_find_param (char *s, char *param[], int *num_param)
{
    *num_param = 0;
    int start_new_word = 1, comment_found = 0;
    if (s == NULL) return NULL;

    while(*s)
    {
        if(*s == '\n')
        {
            *s = '\0';
            return s + sizeof(char);
        }
        else if (comment_found)
        {
            // Do nothing
        }
        else if (*s == '#')
        {
            *s = '\0';
            comment_found = 1;
        }
        else if(isspace(*s))
        {
            *s = '\0';
            start_new_word = 1;
        }
        else if (start_new_word)
        {
            param[*num_param] = s;
            ++(*num_param);
            start_new_word = 0;			
        }
        ++s;
    }
    return NULL;
}




/*----------------------------------------------------------------------------80
    Read and process the inputs from the "run.in" file.
------------------------------------------------------------------------------*/
void GPUMD::run
(
    char *input_dir,  
    Parameters *para,
    CPU_Data *cpu_data, 
    GPU_Data *gpu_data,
    Force *force,
    Integrate *integrate,
    Measure *measure 
)
{
    char file_run[FILE_NAME_LENGTH];
    strcpy(file_run, input_dir);
    strcat(file_run, "/run.in");
    char *input = get_file_contents(file_run);
    char *input_ptr = input; // Keep the pointer in order to free later

    // Iterate the rows
    const int max_num_param = 10; // never use more than 9 parameters
    int num_param;
    char *param[max_num_param];

    initialize_run(para); // set some default values before the first run

    while (input_ptr)
    {
        // get one line from the input file
        input_ptr = row_find_param(input_ptr, param, &num_param);
        if (num_param == 0) { continue; } 

        // set default values
        int is_potential = 0;
        int is_velocity = 0;
        int is_run = 0;

        // parse a line of the input file 
        parse
        (
            param, num_param, para, force, integrate, measure,
            &is_potential, &is_velocity, &is_run
        );

        // check for some special keywords
        if (is_potential) 
        {  
            force->initialize(input_dir, para, cpu_data, gpu_data);
            force->compute(para, gpu_data);
            #ifdef FORCE
            // output the initial forces (for lattice dynamics calculations)
            int m = sizeof(real) * para->N;
            real *cpu_fx = cpu_data->fx;
            real *cpu_fy = cpu_data->fy;
            real *cpu_fz = cpu_data->fz;
            CHECK(cudaMemcpy(cpu_fx, gpu_data->fx, m, cudaMemcpyDeviceToHost));
            CHECK(cudaMemcpy(cpu_fy, gpu_data->fy, m, cudaMemcpyDeviceToHost));
            CHECK(cudaMemcpy(cpu_fz, gpu_data->fz, m, cudaMemcpyDeviceToHost));
	    char file_force[FILE_NAME_LENGTH];
            strcpy(file_force, input_dir);
            strcat(file_force, "/f.out");
            FILE *fid_force = my_fopen(file_force, "w");
            for (int n = 0; n < para->N; n++)
            {
                fprintf
                (
                    fid_force, "%20.10e%20.10e%20.10e\n", 
                    cpu_fx[n], cpu_fy[n], cpu_fz[n]
                );
            }
            fflush(fid_force);
            fclose(fid_force);
            #endif
        }
        if (is_velocity)  
        { 
            process_velocity(para, cpu_data, gpu_data); 
        }
        if (is_run)
        { 
            process_run
            (
                param, num_param, input_dir, para, cpu_data, gpu_data, 
                force, integrate, measure
            );
            
            initialize_run(para); // change back to the default
        }
    }

    MY_FREE(input); // Free the input file contents
}




