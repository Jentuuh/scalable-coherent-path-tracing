#pragma once

#include <optix_device.h>

#include "LaunchParams.hpp"
#include "glm/glm.hpp"
#include "glm/gtx/transform.hpp"
#include "glm/gtc/type_ptr.hpp"

using namespace mcrt;

namespace mcrt {
    // Launch parameters in constant memory, filled in by optix upon
    // optixLaunch (this gets filled in from the buffer we pass to
    // optixLaunch)
    extern "C" __constant__ LaunchParams optixLaunchParams;


    // for this simple example, we have a single ray type
    enum { SURFACE_RAY_TYPE = 0, RAY_TYPE_COUNT };

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

    //------------------------------------------------------------------------------
    // closest hit and anyhit programs for radiance-type rays.
    //
    // Note eventually we will have to create one pair of those for each
    // ray type and each geometry type we want to render; but this
    // simple example doesn't use any actual geometries yet, so we only
    // create a single, dummy, set of them (we do have to have at least
    // one group of them to set up the SBT)
    //------------------------------------------------------------------------------

    extern "C" __global__ void __closesthit__radiance()
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

        // ------------------------------------------------------------------
        // compute normal, using either shading normal (if avail), or
        // geometry normal (fallback)
        // ------------------------------------------------------------------
        glm::vec3 N;
        if (sbtData.normal) {
            N = (1.f - u - v) * sbtData.normal[index.x]
                + u * sbtData.normal[index.y]
                + v * sbtData.normal[index.z];
        }
        else {
            const glm::vec3& A = sbtData.vertex[index.x];
            const glm::vec3& B = sbtData.vertex[index.y];
            const glm::vec3& C = sbtData.vertex[index.z];
            N = normalize(cross(B - A, C - A));
        }
        N = normalize(N);

        // ------------------------------------------------------------------
        // compute diffuse material color, including diffuse texture, if
        // available
        // ------------------------------------------------------------------
        glm::vec3 diffuseColor = sbtData.color;
        if (sbtData.hasTexture && sbtData.texcoord) {
            // Barycentric tex coords
            const glm::vec2 tc
                = (1.f - u - v) * sbtData.texcoord[index.x]
                + u * sbtData.texcoord[index.y]
                + v * sbtData.texcoord[index.z];

            float4 fromTexf4 = tex2D<float4>(sbtData.texture, tc.x, tc.y);
            glm::vec4 fromTexture = glm::vec4{ fromTexf4.x,fromTexf4.y,fromTexf4.z,fromTexf4.w };

            diffuseColor = (glm::vec3)fromTexture;
        }

        // ------------------------------------------------------------------
        // perform some simple "NdotD" shading
        // ------------------------------------------------------------------
        float3 rayDirf3 = optixGetWorldRayDirection();
        const glm::vec3 rayDir = { rayDirf3.x, rayDirf3.y, rayDirf3.z };
        const float cosDN = 0.2f + .8f * fabsf(dot(rayDir, N));

        glm::vec3& prd = *(glm::vec3*)getPRD<glm::vec3>();
        prd = cosDN * diffuseColor;
    }

    extern "C" __global__ void __anyhit__radiance()
    { /*! for this simple example, this will remain empty */
    }


    //------------------------------------------------------------------------------
    // miss program that gets called for any ray that did not have a
    // valid intersection
    //
    // as with the anyhit/closest hit programs, in this example we only
    // need to have _some_ dummy function to set up a valid SBT
    // ------------------------------------------------------------------------------

    extern "C" __global__ void __miss__radiance()
    {
        glm::vec3& prd = *(glm::vec3*)getPRD<glm::vec3>();
        prd = glm::vec3{ 1.0f, 1.0f, 1.0f };
    }

    //------------------------------------------------------------------------------
    // ray gen program - the actual rendering happens in here
    //------------------------------------------------------------------------------
    extern "C" __global__ void __raygen__renderFrame()
    {
        // ------------------------------------------------------------------
        // for this example, produce a simple test pattern:
        // ------------------------------------------------------------------

        // compute a test pattern based on pixel ID
        const int ix = optixGetLaunchIndex().x;
        const int iy = optixGetLaunchIndex().y;

        const auto& camera = optixLaunchParams.camera;

        // our per-ray data for this example. what we initialize it to
        // won't matter, since this value will be overwritten by either
        // the miss or hit program, anyway
        glm::vec3 pixelColorPRD = glm::vec3(0.f);

        // the values we store the PRD pointer in:
        uint32_t u0, u1;
        packPointer(&pixelColorPRD, u0, u1);

        // normalized screen plane position, in [0,1]^2
        const glm::vec2 screen(glm::vec2{ float(ix) + .5f, float(iy) + .5f }
            / glm::vec2{ optixLaunchParams.frame.size });

        // generate ray direction
        glm::vec3 rayDir = glm::normalize(camera.direction
            + (screen.x - 0.5f) * camera.horizontal
            + (screen.y - 0.5f) * camera.vertical);

        float3 camPos = float3{ camera.position.x, camera.position.y, camera.position.z };
        float3 rayDirection = float3{ rayDir.x, rayDir.y, rayDir.z };

        optixTrace(optixLaunchParams.traversable,
            camPos,
            rayDirection,
            0.f,    // tmin
            1e20f,  // tmax
            0.0f,   // rayTime
            OptixVisibilityMask(255),
            OPTIX_RAY_FLAG_DISABLE_ANYHIT,//OPTIX_RAY_FLAG_NONE,
            SURFACE_RAY_TYPE,             // SBT offset
            RAY_TYPE_COUNT,               // SBT stride
            SURFACE_RAY_TYPE,             // missSBTIndex 
            u0, u1);

        const int r = int(255.99f * pixelColorPRD.x);
        const int g = int(255.99f * pixelColorPRD.y);
        const int b = int(255.99f * pixelColorPRD.z);

        // convert to 32-bit rgba value (we explicitly set alpha to 0xff
        // to make stb_image_write happy ...
        const uint32_t rgba = 0xff000000
            | (r << 0) | (g << 8) | (b << 16);


        // and write to frame buffer ...
        const uint32_t fbIndex = ix + iy * optixLaunchParams.frame.size.x;
        optixLaunchParams.frame.colorBuffer[fbIndex] = rgba;
    }


}