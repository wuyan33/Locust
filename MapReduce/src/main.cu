#define _GNU_SOURCE
#include <string>
#include <stdio.h>
#include <stdlib.h>
#include <iostream>
#include <fstream>
#include <sstream>
#include <algorithm>
#include <cuda_runtime.h>
#include <thrust/device_vector.h>
#include <thrust/execution_policy.h>
#include <thrust/partition.h>
#include <thrust/sort.h>
#include <chrono>
#include "util.h"
#include "KeyValue.h"

#define MAX_LINES_FILE_READ 5800
#define EMITS_PER_LINE 20
#define MAX_EMITS (MAX_LINES_FILE_READ * EMITS_PER_LINE)
#define GPU_IMPLEMENTATION 1
#define SHARE_MEMORY 1

#define GRID_SIZE 128
#define BLOCK_SIZE 256

#define SHARED_MEMORY_SIZE 32

#define WINDOWS 0
#define LINUX 1
#define COMPILE_OS WINDOWS

#define MODE_SINGLE	1
#define MODE_MULTI	2

#define STAGE_MAP		1
#define STAGE_REDUCE	2

#if GPU_IMPLEMENTATION
__host__ void loadFile(char fname[], KeyValuePair* kvs, int* length, int line_start, int line_end) {
	std::ifstream input(fname);
	int line_num = -1;
	for (std::string line; getline(input, line); )
	{
		line_num++;
		int line_idx = line_num;
		if (line_start != -1 && line_start > line_num) {
			continue;
		} else if (line_start!= -1 && line_num >= line_end) {
			break;
		}
		if (line_start != -1) {
			line_idx = line_num - line_start;
		}
		char *cstr = new char[line.length() + 1];
		my_strcpy(cstr, line.c_str());
		//itoa(line_num, kvs[line_num].key, 10);
		snprintf(kvs[line_idx].key,10,"%d", line_num);
		my_strcpy(kvs[line_idx].value, cstr);
		delete[] cstr;
	}
	if (line_start < 0) line_start = 0;
	*length = line_num - line_start;
}

__host__ void loadIntermediateFile(char fname[], KeyIntValuePair* kvs, int* length, int line_start, int line_end) {
	std::ifstream input(fname);
	int line_num = -1;
	for (std::string line; getline(input, line); )
	{
		line_num++;
		int line_idx = line_num;
		if (line_start != -1 && line_start > line_num) {
			continue;
		} else if (line_start!= -1 && line_num >= line_end) {
			break;
		}
		if (line_start != -1) {
			line_idx = line_num - line_start;
		}
		char *cstr = new char[line.length() + 1];
		my_strcpy(cstr, line.c_str());

		// Split on first tab
		int i = 0;
		while (cstr[i] != '\0') {
			if (cstr[i] == '\t') {
				cstr[i] = '\0';
				i++;
				break;
			}
			i++;
		}
		my_strcpy(kvs[line_idx].key, cstr);
		int val = strtol(&cstr[i], (char **)NULL, 10);
		kvs[line_idx].value = val;
		kvs[line_idx].count = 0;

		delete[] cstr;
	}
	if (line_start < 0) line_start = 0;
	*length = line_num - line_start;
}


__host__ __device__ void printKeyValues(KeyValuePair* kvs, int length) {
	for(int i = 0; i < length; i++) {
		if (my_strlen(kvs[i].key) == 0) {
			//printf("[%i = null]\n", i);
		} else {
			printf("print key: %s \t value: %s\n", kvs[i].key, kvs[i].value);
		}
	}
}

__host__ void writeKeyIntValues(std::FILE* stream, KeyIntValuePair* kvs, int length) {
	for (int i = 0; i < length; i++) {
		if (my_strlen(kvs[i].key) == 0) {
			//printf("[%i = null]\n", i);
		} else {
			fprintf(stream, "%s \t%d\n", kvs[i].key, kvs[i].value);
		}
	}
}

__host__ __device__ void printKeyIntValues(KeyIntValuePair* kvs, int length) {
	for (int i = 0; i < length; i++) {
		if (my_strlen(kvs[i].key) == 0) {
			//printf("[%i = null]\n", i);
		} else {
			// Can't just call writeKeyIntValues due to stdout being undefined in device
			printf("print key: %s \t val: %d \t count: %d\n", kvs[i].key, kvs[i].value, kvs[i].count);
		}
	}}

__host__ __device__ void map(KeyValuePair kv, KeyIntValuePair* out, int i, bool is_device) {
	char* pSave = NULL;
	char* tokens = my_strtok_r(kv.value, " ,.-;:'()\"\t", &pSave);
	int count = 0;
	while (tokens != NULL) {
		if (count >= EMITS_PER_LINE) {
			printf("WARN: Exceeded emit limit\n");
			break;
		}
		KeyIntValuePair* curOut = &out[i * EMITS_PER_LINE + count];
		my_strcpy(curOut->key, tokens);
		curOut->value = 1;
		//my_strcpy(curOut->value, "1");
		//printf("out [%d][%d] key: %s, value: %s \n", i, count, curOut->key, curOut->value);
		tokens = my_strtok_r(NULL, " ,.-;:'()\"\t", &pSave);
		count++;
	}
}

__global__ void kernMap(KeyValuePair* in, KeyIntValuePair* out, int length) {
	int i = blockIdx.x * blockDim.x + threadIdx.x;
	if (i >= length) return;
	map(in[i], out, i, 1);
}

__global__ void kernFindUniqBool(KeyIntValuePair* in, KeyIntValuePair* out, int length) {
	int i = blockIdx.x * blockDim.x + threadIdx.x;
	if (i >= length) return;
#if SHARE_MEMORY
	if (i == 0) {
		KeyIntValuePair* curOut = &out[i];
		my_strcpy(curOut->key, in[i].key);
		curOut->value = i;
		curOut->count = 0;
		return;
	}
	__shared__ KeyIntValuePair shared_kvs[BLOCK_SIZE];
	shared_kvs[i % BLOCK_SIZE] = in[i];
	__syncthreads();
	if (i % BLOCK_SIZE != 0 && my_strcmp(shared_kvs[i % BLOCK_SIZE - 1].key, shared_kvs[i % BLOCK_SIZE].key)) {
		KeyIntValuePair* curOut = &out[i];
		my_strcpy(curOut->key, in[i].key);
		curOut->value = i;
		curOut->count = 0;
		return;
	}
	else if (i % BLOCK_SIZE == 0 && my_strcmp(in[i].key, in[i - 1].key)) {
		KeyIntValuePair* curOut = &out[i];
		my_strcpy(curOut->key, in[i].key);
		curOut->value = i;
		curOut->count = 0;
		return;
	}
	else {
		KeyIntValuePair* curOut = &out[i];
		my_strcpy(curOut->key, "");
		curOut->value = 0;
	}
#else
	if (i == 0 || my_strcmp(in[i].key, in[i - 1].key)) {
		KeyIntValuePair* curOut = &out[i];
		my_strcpy(curOut->key, in[i].key);
		curOut->value = i;
		curOut->count = 0;
		return;
	}
	else {
		KeyIntValuePair* curOut = &out[i];
		my_strcpy(curOut->key, "");
		curOut->value = 0;
	}
#endif
}

__global__ void kernGetCount(KeyIntValuePair* in, int length, int end) {
	int i = blockIdx.x * blockDim.x + threadIdx.x;
	if (i >= length) return;
#if SHARE_MEMORY
	__shared__ KeyIntValuePair shared_kvs_count[BLOCK_SIZE];
	shared_kvs_count[i % BLOCK_SIZE] = in[i];
	__syncthreads();
	if (i == length - 1) {
		KeyIntValuePair* curOut = &in[i];
		curOut->count = end - curOut->value;
		return;
	}
	KeyIntValuePair* curOut = &in[i];
	if (i % BLOCK_SIZE == BLOCK_SIZE - 1) {
		curOut->count = in[i + 1].value - curOut->value;
	}
	else {
		curOut->count = shared_kvs_count[i % BLOCK_SIZE + 1].value - curOut->value;
	}
#else
	KeyIntValuePair* curOut = &in[i];
	if (i == length - 1) {
		curOut->count = end - curOut->value;
	}
	else {
		curOut->count = in[i + 1].value - curOut->value;
	}
#endif
}

#else

__host__ void loadFile(char fname[], KeyValuePair** kvs, int* length) {
#if COMPILE_OS == WINDOWS
	std::ifstream input(fname);
	int line_num = 0;

	for (std::string line; getline(input, line); )
	{
		
		char *cstr = new char[line.length() + 1];
		strcpy(cstr, line.c_str());
		kvs[line_num] = new KeyValuePair();
		KeyValuePair* curkvs = kvs[line_num];		
		my_itoa(line_num, curkvs->key, 10);
		my_strcpy(curkvs->value, cstr);
		line_num++;
		delete[] cstr;
	}
	*length = line_num;
#elif COMPILE_OS == LINUX
	FILE* fp = fopen(fname, "r");
	if (fp == NULL)
		exit(EXIT_FAILURE);

	char* line = NULL;
	size_t len = 0;
	int line_num = 0;
	while ((getline(&line, &len, fp)) != -1) {
		//printf("%s", line);
		kvs[line_num] = new KeyValuePair(line_num, line);
		line_num++;
	}
	fclose(fp);
	if (line)
		free(line);
	*length = line_num;
#endif
}

__host__ __device__ void printKeyValues(KeyValuePair** kvs, int length) {
	for (int i = 0; i < length; i++) {
		if (kvs[i] == NULL) {
			//printf("[%i = null]\n", i);
		}
		else {
			printf("print key: %s \t value: %s\n", kvs[i]->key, kvs[i]->value);
		}
	}
}

__host__ __device__ void emit(KeyValuePair kv, KeyValuePair** out, int n) {
	out[n] = new KeyValuePair(kv);
}

__host__ __device__ void map(KeyValuePair kv, KeyValuePair** out, int n, bool is_device) {
	char* pSave = NULL;
	char* tokens = my_strtok_r(kv.value, " ,.-;:'()\"\t", &pSave);
	int i = 0;
	while (tokens != NULL) {
		if (i >= EMITS_PER_LINE) {
			printf("WARN: Exceeded emit limit\n");
			return;
		}
		out[n * EMITS_PER_LINE + i] = new KeyValuePair();
		KeyValuePair* curOut = out[n * EMITS_PER_LINE + i];
		my_strcpy(curOut->key, tokens);
		my_strcpy(curOut->value, "1");
		tokens = my_strtok_r(NULL, " ,.-;:'()\"\t", &pSave);
		i++;
	}
}

__host__ void cpuMap(KeyValuePair** in, KeyValuePair** out, int length) {
	for (int i = 0; i < length; i++) {
		map(*in[i], out, i, 0);
	}
}

__global__ void kernMap(KeyValuePair** in, KeyValuePair** out, int length) {
	int i = blockIdx.x * blockDim.x + threadIdx.x;
	if (i >= length) return;
	//printf("Reading input key: %s, %s", in[i]->key, in[i]->value);
	map(*in[i], out, i * EMITS_PER_LINE, 1);
}

__host__ void reduce(int start, int end, KeyValuePair** in, KeyValuePair** out, int n) {
	char* key = in[start]->key;
	char value[50];
	sprintf(value, "%i", end - start);
	out[n] = new KeyValuePair();
	KeyValuePair* curOut = out[n];
	my_strcpy(curOut->key, key);
	my_strcpy(curOut->value, value);
}


__host__ void cpuReduce(KeyValuePair** in, KeyValuePair** out, int length) {
	if (in[0] == NULL) return;

	char* key = in[0]->key;
	int start = 0;
	int n = 0;
	for (int i = 0; i < length; i++) {
		if (in[i] == NULL || my_strcmp(key, in[i]->key) != 0) {
			reduce(start, i, in, out, n);
			if (in[i] == NULL) {
				return; //Sorted, so we must be at the end
			}

			key = in[i]->key;
			start = i;
			n++; //TODO this math doesn't work out, ensure we can't overflow keys
		}
	}
}
#endif

__host__ int main(int argc, char* argv[]) {
	typedef std::chrono::high_resolution_clock Clock;
	std::cout << "Running\n";

	if (argc < 2) {
		printf("Missing or invalid arguments.\n");
		printf("mapreduce <filename> [line_start] [line_end] [node_num] [stage]\n");
		return -1;
	}
	int start_line = -1;
	int end_line = -1;
	if (argc > 2) {
		char* ptr;
		start_line = strtol(argv[2], &ptr, 10);
		end_line = strtol(argv[3], &ptr, 10);
		printf("Using custom start and end locations: (%i, %i)\n", start_line, end_line);
	}
	int stage = 0;
	int mode = MODE_SINGLE;
	int node_num = 0;
	if (argc > 4) {
		char* ptr;
		node_num = strtol(argv[4], &ptr, 10);
		stage = strtol(argv[5], &ptr, 10);
		if (stage) {
			mode = MODE_MULTI;
		}
	}

	char* filename = argv[1];
#if GPU_IMPLEMENTATION
	// Sort filtered map output
	int length = 0;

	KeyIntValuePair* dev_map_kvs = NULL;
	cudaMalloc((void **)&dev_map_kvs, MAX_EMITS * sizeof(KeyIntValuePair));

	KeyValuePair* dev_file_kvs = NULL;

	if (!stage || stage == STAGE_MAP) {
	KeyValuePair file_kvs[MAX_LINES_FILE_READ] = { NULL };
	loadFile(filename, file_kvs, &length, start_line, end_line);
	printf("Length: %i\n", length);

	cudaMalloc((void **)&dev_file_kvs, MAX_LINES_FILE_READ * sizeof(KeyValuePair));
	cudaMemcpy(dev_file_kvs, file_kvs, MAX_LINES_FILE_READ * sizeof(KeyValuePair), cudaMemcpyHostToDevice);

	auto t0 = Clock::now();
	kernMap << <GRID_SIZE, BLOCK_SIZE >> > (dev_file_kvs, dev_map_kvs, length);
	auto t1 = Clock::now();
	printf("GPU mapping %d nanoseconds \n", t1 - t0);

	// stream compaction
	KeyIntValuePair* iter_end = thrust::partition(thrust::device, dev_map_kvs, dev_map_kvs + MAX_EMITS, KeyIntValueNotEmpty());
	int kv_num_map = iter_end - dev_map_kvs;
	//printf("Remain kv number is %d \n", kv_num_map);
	thrust::device_ptr<KeyIntValuePair> dev_ptr(dev_map_kvs);
	thrust::sort(thrust::device, dev_ptr, dev_ptr + kv_num_map, KIVComparator());

	auto t2 = Clock::now();
	printf("GPU stream compaction and sorting %d nanoseconds \n", t2 - t1);

	// MULTI_STAGE
	if (mode == MODE_MULTI) {
		// Move to host memory
		KeyIntValuePair* map_kvs = (KeyIntValuePair*)malloc(MAX_EMITS * sizeof(KeyIntValuePair));
		cudaMemcpy(map_kvs, dev_map_kvs, MAX_EMITS * sizeof(KeyIntValuePair), cudaMemcpyDeviceToHost);
		//printKeyIntValues(map_kvs, MAX_EMITS);

		// Write intermediate results to file
		std::FILE* f = fopen("/tmp/out.txt", "w");
		writeKeyIntValues(f, map_kvs, MAX_EMITS);
		fclose(f);
		printf("MODE_MULTI: Finished map\n");
		return 0; //Exit, master will start back up
	}
	}

	if (!stage || stage == STAGE_REDUCE) {
	if (mode == MODE_MULTI) {

		// TODO: Refactor into it's own call
		KeyIntValuePair* reduce_kvs = (KeyIntValuePair*)malloc(MAX_EMITS * sizeof(KeyIntValuePair));
		loadIntermediateFile("/tmp/out.txt", reduce_kvs, &length, -1, -1);

		// Copy to device
		cudaMemcpy(dev_map_kvs, reduce_kvs, MAX_EMITS * sizeof(KeyIntValuePair), cudaMemcpyHostToDevice);
		//printKeyIntValues(reduce_kvs, length);
	}
	KeyIntValuePair* iter_end = thrust::partition(thrust::device, dev_map_kvs, dev_map_kvs + MAX_EMITS, KeyIntValueNotEmpty());
	int kv_num_map = iter_end - dev_map_kvs;

	KeyIntValuePair* dev_reduce_kvs = NULL;
	cudaMalloc((void **)&dev_reduce_kvs, kv_num_map * sizeof(KeyIntValuePair));
	
	auto t3 = Clock::now();
	kernFindUniqBool << <GRID_SIZE, BLOCK_SIZE >> >(dev_map_kvs, dev_reduce_kvs, kv_num_map);


	//KeyIntValuePair* reduce_kvs = NULL;
	//reduce_kvs = (KeyIntValuePair*)malloc(kv_num_map * sizeof(KeyIntValuePair));
	//cudaMemcpy(reduce_kvs, dev_reduce_kvs, kv_num_map * sizeof(KeyIntValuePair), cudaMemcpyDeviceToHost);
	//printKeyIntValues(reduce_kvs, kv_num_map);

	KeyIntValuePair* iter_end_reduce = thrust::partition(thrust::device, dev_reduce_kvs, dev_reduce_kvs + kv_num_map, KeyIntValueNotEmpty());
	int kv_num_reduce = iter_end_reduce - dev_reduce_kvs;

	kernGetCount << <GRID_SIZE, BLOCK_SIZE >> >(dev_reduce_kvs, kv_num_reduce, kv_num_map);

	auto t4 = Clock::now();
	printf("GPU reduce %d nanoseconds \n", t4 - t3);

	KeyIntValuePair* reduce_kvs = NULL;
	reduce_kvs = (KeyIntValuePair*)malloc(kv_num_reduce * sizeof(KeyIntValuePair));
	cudaMemcpy(reduce_kvs, dev_reduce_kvs, kv_num_reduce * sizeof(KeyIntValuePair), cudaMemcpyDeviceToHost);
	printKeyIntValues(reduce_kvs, kv_num_reduce);

	//free(map_kvs);

	if (!stage || stage == STAGE_MAP) {
		cudaFree(dev_file_kvs);
	}
	cudaFree(dev_map_kvs);

	if (!stage || stage == STAGE_REDUCE) {
		free(reduce_kvs);
		cudaFree(dev_reduce_kvs);
	}
	}
 
	
#else
	int length = 0;
	KeyValuePair* file_kvs[MAX_LINES_FILE_READ] = { NULL };
	loadFile(filename, file_kvs, &length);
	KeyValuePair* map_kvs[MAX_EMITS] = { NULL };
	auto t0 = Clock::now();
	cpuMap(file_kvs, map_kvs, length);
	auto t1 = Clock::now();
	printf("CPU mapping %d nanoseconds \n", t1 - t0);
	std::sort(map_kvs, map_kvs + MAX_EMITS, KVComparatorCPU());
	auto t2 = Clock::now();
	printf("CPU sorting %d nanoseconds \n", t2 - t1);
	// Reduce stage
	KeyValuePair* reduce_kvs[MAX_EMITS] = { NULL };
	auto t3 = Clock::now();
	cpuReduce(map_kvs, reduce_kvs, MAX_EMITS);
	auto t4 = Clock::now();
	printf("CPU reducing %d nanoseconds \n", t4 - t3);
	std::sort(reduce_kvs, reduce_kvs + MAX_EMITS, KVComparatorCPU());
	printKeyValues(reduce_kvs, MAX_EMITS);
	//KeyValuePair* map_kvs = NULL;
	//map_kvs = (KeyValuePair*)malloc(MAX_EMITS * sizeof(KeyValuePair));
	//auto t0 = Clock::now();
	//cpuMap(file_kvs, map_kvs, length);
	//auto t1 = Clock::now();
	//printf("%d nanoseconds \n", t1 - t0);

	//std::sort(map_kvs, map_kvs + MAX_EMITS, KVComparator());

	//// Reduce stage
	//KeyValuePair* reduce_kvs = NULL;
	//reduce_kvs = (KeyValuePair*)malloc(MAX_EMITS * sizeof(KeyValuePair));
	//cpuReduce(map_kvs, reduce_kvs, MAX_EMITS);
	//std::sort(reduce_kvs, reduce_kvs + MAX_EMITS, KVComparator());
	//printKeyValues(reduce_kvs, MAX_EMITS);
	//
	//free(map_kvs);
	//free(reduce_kvs);
#endif
	
	std::cout << "\nDone\n";
	//std::cin.ignore();
	return 0;
}
