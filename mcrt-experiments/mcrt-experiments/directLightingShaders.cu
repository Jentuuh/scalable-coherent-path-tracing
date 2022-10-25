#pragma once

#include <optix_device.h>
#include "curand.h"

#include "LaunchParams.hpp"
#include "glm/glm.hpp"
#include "glm/gtx/transform.hpp"
#include "glm/gtc/type_ptr.hpp"

#define NUM_SAMPLES_PER_STRATIFY_CELL 64

using namespace mcrt;

namespace mcrt {

    extern "C" __constant__ LaunchParamsDirectLighting optixLaunchParams;

    static __forceinline__ __device__
        void* unpackPointer(uint32_t i0, uint32_t i1)
    {
        const uint64_t uptr = static_cast<uint64_t>(i0) << 32 | i1;
        void* ptr = reinterpret_cast<void*>(uptr);
        return ptr;
    }

    static __forceinline__ __device__
        void  packPointer(void* ptr, uint32_t& i0, uint32_t& i1)
    {
        const uint64_t uptr = reinterpret_cast<uint64_t>(ptr);
        i0 = uptr >> 32;
        i1 = uptr & 0x00000000ffffffff;
    }

    template<typename T>
    static __forceinline__ __device__ T* getPRD()
    {
        const uint32_t u0 = optixGetPayload_0();
        const uint32_t u1 = optixGetPayload_1();
        return reinterpret_cast<T*>(unpackPointer(u0, u1));
    }

    extern "C" __global__ void __closesthit__radiance__direct__lighting()
    {
        const MeshSBTData& sbtData
            = *(const MeshSBTData*)optixGetSbtDataPointer();

        // ------------------------------------------------------------------
        // gather some basic hit information
        // ------------------------------------------------------------------
        const int   primID = optixGetPrimitiveIndex();
        const glm::ivec3 index = sbtData.index[primID];
        const float u = optixGetTriangleBarycentrics().x;
        const float v = optixGetTriangleBarycentrics().y;

        // Barycentric tex coords
        const glm::vec2 tc
            = (1.f - u - v) * sbtData.texcoord[index.x]
            + u * sbtData.texcoord[index.y]
            + v * sbtData.texcoord[index.z];

        // Pass the texture coordinates of the ray-geometry intersection
        // to the PRD, so we can read them out in our launch shader.
        glm::vec2& prd = *(glm::vec2*)getPRD<glm::vec2>();
        prd = tc;
    }

    extern "C" __global__ void __anyhit__radiance__direct__lighting(){
        // Do nothing
    }

    extern "C" __global__ void __miss__radiance__direct__lighting()
    {
        // If the light ray did not hit any geometry, we'll write (-1;-1) to the 
        // texture coordinate so we can verify this later
        glm::vec2& prd = *(glm::vec2*)getPRD<glm::vec2>();
        prd = glm::vec2{ -1.0f, -1.0f};
    }

    extern "C" __global__ void __raygen__renderFrame__direct__lighting()
    {
        const auto& lights = optixLaunchParams.lights;

        // Get thread indices
        const int lightIndex = optixGetLaunchIndex().x;
        const int stratifyIndexX = optixGetLaunchIndex().y;
        const int stratifyIndexY = optixGetLaunchIndex().z;

        // Look up the light properties for the light in question
        LightData lightProperties = optixLaunchParams.lights[lightIndex];
        float stratifyCellWidth = lightProperties.width / optixLaunchParams.stratifyResX;
        float stratifyCellHeigth = lightProperties.height / optixLaunchParams.stratifyResY;
        
        // We start from the light origin, and calculate the origin of the current stratification cell based on the stratifyIndex of this thread
        glm::vec3 cellOrigin = lightProperties.origin + (stratifyIndexX * stratifyCellWidth * lightProperties.du) + (stratifyIndexY * stratifyCellHeigth * lightProperties.dv);
        glm::vec3 cellMax = cellOrigin + (stratifyCellWidth * lightProperties.du) + (stratifyCellHeigth * lightProperties.dv);

        // Send out a ray for each sample
        for (int i = 0; i < NUM_SAMPLES_PER_STRATIFY_CELL; i++)
        {
            // The per-ray data in which we'll store the texture coordinate of the vertex that the ray hits
            glm::vec2 rayTexCoordPRD = glm::vec2(0.0f);
            uint32_t u0, u1;
            packPointer(&rayTexCoordPRD, u0, u1);

            // Randomize ray origins within a cell
            // TODO: MAKE THIS RANDOMIZED!!!
            float cellXOffset = i / NUM_SAMPLES_PER_STRATIFY_CELL;
            float cellYOffset = i / NUM_SAMPLES_PER_STRATIFY_CELL;
            glm::vec3 rayOrigin = cellOrigin + (cellXOffset * stratifyCellWidth * lightProperties.du) + (cellYOffset * stratifyCellHeigth * lightProperties.dv);

            // Orthogonal lighting
            glm::vec3 rayDir = lightProperties.normal;

            float3 rayOrigin3f = float3{ rayOrigin.x, rayOrigin.y, rayOrigin.z };
            float3 rayDirection3f = float3{ rayDir.x, rayDir.y, rayDir.z };

            optixTrace(optixLaunchParams.traversable,
                rayOrigin3f,
                rayDirection3f,
                0.f,    // tmin
                1e20f,  // tmax
                0.0f,   // rayTime
                OptixVisibilityMask(255),
                OPTIX_RAY_FLAG_DISABLE_ANYHIT,//OPTIX_RAY_FLAG_NONE,
                0,  // SBT offset
                1,  // SBT stride
                0,  // missSBTIndex 
                u0, u1);

            if (rayTexCoordPRD.x != -1.0f && rayTexCoordPRD.y != -1.0f)
            {
                // TODO: WEIGH THE LIGHT CONTRIBUTION BY COSINE OF THE INCIDENT RAY ANGLE!
                // Calculate light contribution
                const int r = int(255.99f * lightProperties.power.x);
                const int g = int(255.99f * lightProperties.power.y);
                const int b = int(255.99f * lightProperties.power.z);

                // convert to 32-bit rgba value (we explicitly set alpha to 0xff
                // to make stb_image_write happy ...
                const uint32_t rgba = 0xff000000
                    | (r << 0) | (g << 8) | (b << 16);

                // Write to color buffer
                const uint32_t uvIndex = rayTexCoordPRD.x + rayTexCoordPRD.y * optixLaunchParams.directLightingTexture.size;
                optixLaunchParams.directLightingTexture.colorBuffer[uvIndex] = rgba;
            }
        }
    }

}