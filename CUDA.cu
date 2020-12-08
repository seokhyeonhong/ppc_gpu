#include "CUDA.cuh"
#include "cuda.h"
#include "cuda_runtime_api.h"
#include "cublas_v2.h"

#include <iostream>
#include <cufft.h>
#include <stdio.h>
#include <stdlib.h>
#include <ctime>


// for debugging in GPU
#ifdef DEBUG_GPU
#define GpuErrorCheck(ans) { gpuAssert((ans), __FILE__, __LINE__); }
inline void gpuAssert(cudaError_t code, const char* file, int line)
{

	if (code != cudaSuccess)
	{
		fprintf(stderr, "GPUassert: %s %s %d\n", cudaGetErrorString(code), file, line);
		exit(code);
	}
}
inline void memoryPrint(int line)
{
	float free_m, total_m, used_m;
	size_t free_t, total_t;
	cudaMemGetInfo(&free_t, &total_t);
	free_m = (uint)free_t / 1048576.0;
	total_m = (uint)total_t / 1048576.0;
	used_m = total_m - free_m;
	printf("  line .... %d\tfree .... %f MB\ttotal ....%f MB\tused %f MB\n", line, free_m, total_m, used_m);
}
#else
#define GpuErrorCheck(ans) { ans; }
#endif

using namespace cv::cuda;

CUDA::CUDA(void)
{
}

CUDA::~CUDA(void)
{
}


/////////////////////////////////////////////////////////
/////////////////////////////////////////////////////////
////////////////////// Device Code //////////////////////
/////////////////////////////////////////////////////////
/////////////////////////////////////////////////////////

__global__ void make_PC_GPU(
	cuda::PtrStepSz<uchar3> color_src,
	cuda::PtrStepSz<ushort> depth_src,
	double scaleZ,
	double* K,
	double* R_wc_inv,
	double* t_wc,
	double* dev_x,
	double* dev_y,
	double* dev_z,
	uchar* dev_b,
	uchar* dev_g,
	uchar* dev_r)
{
	int x = blockIdx.x * blockDim.x + threadIdx.x;
	int y = blockIdx.y * blockDim.y + threadIdx.y;

	int cols = color_src.cols;

	if (0 <= x && x < color_src.cols && 0 <= y && y < color_src.rows)
	{
		dev_b[y * cols + x] = color_src.ptr(y)[x].x;
		dev_g[y * cols + x] = color_src.ptr(y)[x].y;
		dev_r[y * cols + x] = color_src.ptr(y)[x].z;

		ushort depth_level = depth_src.ptr(y)[x];

		double Z = depth_level_2_Z_s_direct(depth_level, scaleZ);

		double3 C_world = MVG(K, R_wc_inv, t_wc, x, y, Z);
		dev_x[y * cols + x] = C_world.x;
		dev_y[y * cols + x] = C_world.y;
		dev_z[y * cols + x] = C_world.z;
	}
}

__global__ void perform_projection_GPU(
	int ppc_size,
	int cam_num,
	cuda::PtrStepSz<uchar3> proj_img,
	cuda::PtrStepSz<uchar> is_hole_proj_img,
	cuda::PtrStepSz<double> depth_value_img,
	double* dev_ProjMatrix,
	float* dev_x,
	float* dev_geo_y,
	float* dev_z,
	uchar* dev_color_y,
	uchar* dev_u,
	uchar* dev_v,
	bool* dev_occlusion)
{
	//////////////////////////////////
	/// 0		4		8		12 ///
	/// 1		5		9		13 ///
	/// 2		6		10		14 ///
	/// 3		7		11		15 ///
	//////////////////////////////////
	int i = blockDim.x * blockIdx.x + threadIdx.x;
	int _width = depth_value_img.cols, _height = depth_value_img.rows;
	int offset = ppc_size * cam_num;
	
	int proj_offset = 16 * cam_num;
	if (0 <= i && i < ppc_size) {
		i += offset;
		if (!dev_occlusion[i]) {
			// projetion_XYZ_2_UV
			double _u, _v, w;
			_u = dev_ProjMatrix[proj_offset + 0] * dev_x[i] + dev_ProjMatrix[proj_offset + 4] * dev_geo_y[i] + dev_ProjMatrix[proj_offset + 8] * dev_z[i] + dev_ProjMatrix[proj_offset + 12];
			_v = dev_ProjMatrix[proj_offset + 1] * dev_x[i] + dev_ProjMatrix[proj_offset + 5] * dev_geo_y[i] + dev_ProjMatrix[proj_offset + 9] * dev_z[i] + dev_ProjMatrix[proj_offset + 13];
			w = dev_ProjMatrix[proj_offset + 2] * dev_x[i] + dev_ProjMatrix[proj_offset + 6] * dev_geo_y[i] + dev_ProjMatrix[proj_offset + 10] * dev_z[i] + dev_ProjMatrix[proj_offset + 14];

			_u /= w;
			_v /= w;

			int u = (int)lround(_u);
			int v = (int)lround(_v);

			double dist = find_point_dist(w, dev_ProjMatrix);

			bool possible = true;
			if ((u < 0) || (v < 0) || (u > _width - 1) || (v > _height - 1)) {
				possible = false;
			}
			else {
				if (depth_value_img.ptr(v)[u] == -1) {
					depth_value_img.ptr(v)[u] = dist;
					is_hole_proj_img.ptr(v)[u] = 0;
				}
				else {
					if (dist < depth_value_img.ptr(v)[u])
						depth_value_img.ptr(v)[u] = dist;
					else
						possible = false;
				}
			}

			if (possible) {
				proj_img.ptr(v)[u].x = dev_color_y[i];
				proj_img.ptr(v)[u].y = dev_u[i];
				proj_img.ptr(v)[u].z = dev_v[i];
			}
		}
	}

}

__device__ double depth_level_2_Z_s_direct(ushort d, double scaleZ)
{
	return (double)d / scaleZ;
}

__device__ double3 MVG(
	double* K,
	double* R_wc_inv,
	double* t_wc,
	int x,
	int y,
	double Z)
{
	/////////////////////////
	/// 0		3		6 ///
	/// 1		4		7 ///
	/// 2		5		8 ///
	/////////////////////////
	double X_cam = (x - K[6]) * (Z / K[0]);
	double Y_cam = (y - K[7]) * (Z / K[4]);

	// cam coordinate
	double3 C_cam = make_double3(X_cam, Y_cam, Z);

	// assuming R, t as matrix world to cam
	C_cam.x -= t_wc[0];
	C_cam.y -= t_wc[1];
	C_cam.z -= t_wc[2];

	double3 C_world = make_double3(
		R_wc_inv[0] * C_cam.x + R_wc_inv[3] * C_cam.y + R_wc_inv[6] * C_cam.z,
		R_wc_inv[1] * C_cam.x + R_wc_inv[4] * C_cam.y + R_wc_inv[7] * C_cam.z,
		R_wc_inv[2] * C_cam.x + R_wc_inv[5] * C_cam.y + R_wc_inv[8] * C_cam.z);
	
	return C_world;
}

__device__ double find_point_dist(double w, double* projMatrix)
{
	double numerator = 0., denominator = 0., dist = 0.;
	double M[3][3];
	for (int i = 0; i < 3; i++)
		for (int j = 0; j < 3; j++)
			M[i][j] = projMatrix[4 * i + j];

	for (int i = 0; i < 3; i++)
		denominator += (M[2][i] * M[2][i]);

	denominator = sqrt(denominator);
	numerator = determinant(M);

	// sign
	if (numerator < 0) numerator = -1;
	else if (numerator == 0) numerator = 0;
	else numerator = 1;

	numerator = numerator * w;

	if (denominator == 0) {
		printf("Denominator Error\n");
	}
	else dist = (numerator / denominator);

	return dist;
}

__device__ double determinant(double mat[3][3])
{
	double D = 0;

	D = mat[0][0] * ((mat[1][1] * mat[2][2]) - (mat[2][1] * mat[1][2]))
		- mat[0][1] * (mat[1][0] * mat[2][2] - mat[2][0] * mat[1][2])
		+ mat[0][2] * (mat[1][0] * mat[2][1] - mat[2][0] * mat[1][1]);

	return D;
}

///////////////////////////////////////////////////////
///////////////////////////////////////////////////////
////////////////////// Host Code //////////////////////
///////////////////////////////////////////////////////
///////////////////////////////////////////////////////
void CUDA::make_PC(
	Mat color_img,
	Mat depth_img,
	int data_mode,
	double scaleZ,
	double* hst_K,
	double* hst_R_wc_inv,
	double* hst_t_wc,
	double* hst_x,
	double* hst_y,
	double* hst_z,
	uchar* hst_b,
	uchar* hst_g,
	uchar* hst_r)
{
	// TODO: develop to operate for mode 0~3.
	// For now, it can be operated correctly ONLY for mode 4 ~ 13.
	GpuMat color_img_gpu, depth_img_gpu;
	color_img_gpu.upload(color_img);
	depth_img_gpu.upload(depth_img);

	dim3 block(32, 8);
	dim3 grid(divUp(color_img_gpu.cols, block.x), divUp(color_img_gpu.rows, block.y));

	int numpix = color_img.rows * color_img.cols;
	double* dev_x, * dev_y, * dev_z;
	uchar* dev_b, * dev_g, * dev_r;
	double* dev_K, * dev_R_wc_inv, * dev_t_wc;

	memoryPrint(__LINE__);
	GpuErrorCheck(cudaMalloc(&dev_x, sizeof(double) * numpix));
	GpuErrorCheck(cudaMalloc(&dev_y, sizeof(double) * numpix));
	GpuErrorCheck(cudaMalloc(&dev_z, sizeof(double) * numpix));
	GpuErrorCheck(cudaMalloc(&dev_b, sizeof(uchar) * numpix));
	GpuErrorCheck(cudaMalloc(&dev_g, sizeof(uchar) * numpix));
	GpuErrorCheck(cudaMalloc(&dev_r, sizeof(uchar) * numpix));
	GpuErrorCheck(cudaMalloc(&dev_K, sizeof(double) * 9));
	GpuErrorCheck(cudaMalloc(&dev_R_wc_inv, sizeof(double) * 9));
	GpuErrorCheck(cudaMalloc(&dev_t_wc, sizeof(double) * 3));

	GpuErrorCheck(cudaMemcpy(dev_K, hst_K, sizeof(double) * 9, cudaMemcpyHostToDevice));
	GpuErrorCheck(cudaMemcpy(dev_R_wc_inv, hst_R_wc_inv, sizeof(double) * 9, cudaMemcpyHostToDevice));
	GpuErrorCheck(cudaMemcpy(dev_t_wc, hst_t_wc, sizeof(double) * 3, cudaMemcpyHostToDevice));
	make_PC_GPU << < grid, block >> > (color_img_gpu, depth_img_gpu, scaleZ, dev_K, dev_R_wc_inv, dev_t_wc, dev_x, dev_y, dev_z, dev_b, dev_g, dev_r);

	GpuErrorCheck(cudaMemcpy(hst_x, dev_x, sizeof(double) * numpix, cudaMemcpyDeviceToHost));
	GpuErrorCheck(cudaMemcpy(hst_y, dev_y, sizeof(double) * numpix, cudaMemcpyDeviceToHost));
	GpuErrorCheck(cudaMemcpy(hst_z, dev_z, sizeof(double) * numpix, cudaMemcpyDeviceToHost));
	GpuErrorCheck(cudaMemcpy(hst_b, dev_b, sizeof(uchar) * numpix, cudaMemcpyDeviceToHost));
	GpuErrorCheck(cudaMemcpy(hst_g, dev_g, sizeof(uchar) * numpix, cudaMemcpyDeviceToHost));
	GpuErrorCheck(cudaMemcpy(hst_r, dev_r, sizeof(uchar) * numpix, cudaMemcpyDeviceToHost));

	GpuErrorCheck(cudaFree(dev_x));
	GpuErrorCheck(cudaFree(dev_y));
	GpuErrorCheck(cudaFree(dev_z));
	GpuErrorCheck(cudaFree(dev_b));
	GpuErrorCheck(cudaFree(dev_g));
	GpuErrorCheck(cudaFree(dev_r));
	GpuErrorCheck(cudaFree(dev_K));
	GpuErrorCheck(cudaFree(dev_R_wc_inv));
	GpuErrorCheck(cudaFree(dev_t_wc));
	memoryPrint(__LINE__);
}

void CUDA::perform_projection(
	Mat sample_mat,
	uchar** proj_data,
	uchar** is_hole_proj_data,
	double** depth_value_data,
	int total_num_cameras,
	double* hst_ProjMatrix,
	int ppc_size,
	float* hst_x,
	float* hst_geo_y,
	float* hst_z,
	uchar* hst_color_y,
	uchar* hst_u,
	uchar* hst_v,
	bool* hst_occlusion)
{
	int rows = sample_mat.rows;
	int cols = sample_mat.cols;

	int threadsPerBlock = 256;
	int blocksPerGrid =	(ppc_size + threadsPerBlock - 1) / threadsPerBlock;
	float* dev_x, * dev_geo_y, * dev_z;
	uchar* dev_color_y, * dev_u, * dev_v;
	bool* dev_occlusion;
	double* dev_ProjMatrix;
	size_t total_size = ppc_size * total_num_cameras;
	
	clock_t start = clock();
	GpuErrorCheck(cudaMalloc(&dev_x, sizeof(float) * total_size));
	GpuErrorCheck(cudaMalloc(&dev_geo_y, sizeof(float) * total_size));
	GpuErrorCheck(cudaMalloc(&dev_z, sizeof(float) * total_size));
	GpuErrorCheck(cudaMalloc(&dev_color_y, sizeof(uchar) * total_size));
	GpuErrorCheck(cudaMalloc(&dev_u, sizeof(uchar) * total_size));
	GpuErrorCheck(cudaMalloc(&dev_v, sizeof(uchar) * total_size));
	GpuErrorCheck(cudaMalloc(&dev_occlusion, sizeof(bool) * total_size));
	GpuErrorCheck(cudaMalloc(&dev_ProjMatrix, sizeof(double) * 16 * total_num_cameras));

	GpuErrorCheck(cudaMemcpy(dev_x, hst_x, sizeof(float) * total_size, cudaMemcpyHostToDevice));
	GpuErrorCheck(cudaMemcpy(dev_geo_y, hst_geo_y, sizeof(float) * total_size, cudaMemcpyHostToDevice));
	GpuErrorCheck(cudaMemcpy(dev_z, hst_z, sizeof(float) * total_size, cudaMemcpyHostToDevice));
	GpuErrorCheck(cudaMemcpy(dev_color_y, hst_color_y, sizeof(uchar) * total_size, cudaMemcpyHostToDevice));
	GpuErrorCheck(cudaMemcpy(dev_u, hst_u, sizeof(uchar) * total_size, cudaMemcpyHostToDevice));
	GpuErrorCheck(cudaMemcpy(dev_v, hst_v, sizeof(uchar) * total_size, cudaMemcpyHostToDevice));
	GpuErrorCheck(cudaMemcpy(dev_occlusion, hst_occlusion, sizeof(bool) * total_size, cudaMemcpyHostToDevice));
	GpuErrorCheck(cudaMemcpy(dev_ProjMatrix, hst_ProjMatrix, sizeof(double) * 16 * total_num_cameras, cudaMemcpyHostToDevice));
	clock_t end = clock();
	printf("CPU to GPU memcpy: %lf\n", (double)(end - start) / CLOCKS_PER_SEC);

	start = clock();
	for (int cam_num = 0; cam_num < total_num_cameras; ++cam_num) {
		Mat proj_img(rows, cols, CV_8UC3, proj_data[cam_num]);
		Mat hole_img(rows, cols, CV_8UC1, is_hole_proj_data[cam_num]);
		Mat depth_img(rows, cols, CV_64FC1, depth_value_data[cam_num]);
		GpuMat proj_img_gpu, hole_img_gpu, depth_img_gpu;
				
		proj_img_gpu.upload(proj_img);
		hole_img_gpu.upload(hole_img);
		depth_img_gpu.upload(depth_img);
		
		perform_projection_GPU <<< blocksPerGrid, threadsPerBlock >>> (ppc_size, cam_num, proj_img_gpu, hole_img_gpu, depth_img_gpu, dev_ProjMatrix, dev_x, dev_geo_y, dev_z, dev_color_y, dev_u, dev_v, dev_occlusion);
		
		proj_img_gpu.download(proj_img);
		hole_img_gpu.download(hole_img);
		depth_img_gpu.download(depth_img);

		for (int y = 0; y < rows; ++y) {
			for (int x = 0; x < cols; ++x) {
				size_t offset = y * rows + x;
				proj_data[cam_num][offset + 0] = proj_img.at<Vec3b>(y, x)[0];
				proj_data[cam_num][offset + 1] = proj_img.at<Vec3b>(y, x)[1];
				proj_data[cam_num][offset + 2] = proj_img.at<Vec3b>(y, x)[2];
				is_hole_proj_data[cam_num][offset] = hole_img.at<uchar>(y, x);
				depth_value_data[cam_num][offset] = depth_img.at<double>(y, x);
			}
		}
	}
		
	end = clock();
	printf("GPU computation time: %lf\n", (double)(end - start) / CLOCKS_PER_SEC);


	GpuErrorCheck(cudaFree(dev_x));
	GpuErrorCheck(cudaFree(dev_geo_y));
	GpuErrorCheck(cudaFree(dev_z));
	GpuErrorCheck(cudaFree(dev_color_y));
	GpuErrorCheck(cudaFree(dev_u));
	GpuErrorCheck(cudaFree(dev_v));
	GpuErrorCheck(cudaFree(dev_occlusion));
	GpuErrorCheck(cudaFree(dev_ProjMatrix));
}