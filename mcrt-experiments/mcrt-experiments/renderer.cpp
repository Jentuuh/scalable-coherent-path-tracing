#include "renderer.hpp"

// This include may only appear in a SINGLE src file:
#include <optix_function_table_definition.h>
#include <glm/gtc/matrix_access.hpp>
#include <glm/gtx/string_cast.hpp>

// std
#include <iostream>

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb/stb_image_write.h"

#define NUM_SAMPLES_LIGHT 40
#define STRATIFIED_X_SIZE 5
#define STRATIFIED_Y_SIZE 5

namespace mcrt {

    Renderer::Renderer(Scene& scene, const Camera& camera): renderCamera{camera}, scene{scene}
    {
        initOptix();
        updateCamera(camera);

        std::cout << "Creating OptiX context..." << std::endl;
        createContext();

        std::cout << "Filling geometry buffers..." << std::endl;
        fillGeometryBuffers();

        std::cout << "Loading textures..." << std::endl;
        createTextures();

        std::cout << "Setting up pipeline..." << std::endl;
        GeometryBufferHandle geometryData = GeometryBufferHandle{ vertexBuffers, indexBuffers, normalBuffers, texcoordBuffers, textureObjects };
        tutorialPipeline = std::make_unique<DefaultPipeline>( optixContext, geometryData, scene);
        directLightPipeline = std::make_unique<DirectLightPipeline>(optixContext, geometryData, scene);

        std::cout << "Context, module, pipeline, etc, all set up." << std::endl;
        std::cout << "MCRT renderer fully set up." << std::endl;

        // Direct lighting (preprocess)
        initDirectLightingTexture(1024);
        calculateDirectLighting();
    }

    void Renderer::fillGeometryBuffers()
    {
        int bufferSize = scene.numObjects();

        std::cout << bufferSize << std::endl;
        vertexBuffers.resize(bufferSize);
        indexBuffers.resize(bufferSize);
        normalBuffers.resize(bufferSize);
        texcoordBuffers.resize(bufferSize);

        for (int meshID = 0; meshID < scene.numObjects(); meshID++) {
            // upload the model to the device: the builder
            std::shared_ptr<Model> model = scene.getGameObjects()[meshID].model;
            std::shared_ptr<TriangleMesh> mesh = model->mesh;
            vertexBuffers[meshID].alloc_and_upload(scene.getGameObjects()[meshID].getWorldVertices());
            indexBuffers[meshID].alloc_and_upload(mesh->indices);
            if (!mesh->normals.empty())
                normalBuffers[meshID].alloc_and_upload(mesh->normals);
            if (!mesh->texCoords.empty())
                texcoordBuffers[meshID].alloc_and_upload(mesh->texCoords);
        }
    }

    void Renderer::createTextures()
    {
        int numTextures = (int)scene.getTextures().size();

        textureArrays.resize(numTextures);
        textureObjects.resize(numTextures);

        for (int textureID = 0; textureID < numTextures; textureID++) {
            auto texture = scene.getTextures()[textureID];

            cudaResourceDesc res_desc = {};

            cudaChannelFormatDesc channel_desc;
            int32_t width = texture->resolution.x;
            int32_t height = texture->resolution.y;
            int32_t numComponents = 4;
            int32_t pitch = width * numComponents * sizeof(uint8_t);
            channel_desc = cudaCreateChannelDesc<uchar4>();

            cudaArray_t& pixelArray = textureArrays[textureID];
            CUDA_CHECK(MallocArray(&pixelArray,
                &channel_desc,
                width, height));

            CUDA_CHECK(Memcpy2DToArray(pixelArray,
                /* offset */0, 0,
                texture->pixel,
                pitch, pitch, height,
                cudaMemcpyHostToDevice));

            res_desc.resType = cudaResourceTypeArray;
            res_desc.res.array.array = pixelArray;

            cudaTextureDesc tex_desc = {};
            tex_desc.addressMode[0] = cudaAddressModeWrap;
            tex_desc.addressMode[1] = cudaAddressModeWrap;
            tex_desc.filterMode = cudaFilterModeLinear;
            tex_desc.readMode = cudaReadModeNormalizedFloat;
            tex_desc.normalizedCoords = 1;
            tex_desc.maxAnisotropy = 1;
            tex_desc.maxMipmapLevelClamp = 99;
            tex_desc.minMipmapLevelClamp = 0;
            tex_desc.mipmapFilterMode = cudaFilterModePoint;
            tex_desc.borderColor[0] = 1.0f;
            tex_desc.sRGB = 0;

            // Create texture object
            cudaTextureObject_t cuda_tex = 0;
            CUDA_CHECK(CreateTextureObject(&cuda_tex, &res_desc, &tex_desc, nullptr));
            textureObjects[textureID] = cuda_tex;
        }

    }


    void Renderer::initOptix()
    {
        // Get CUDA compatible devices
        cudaFree(0);
        int numDevices;
        cudaGetDeviceCount(&numDevices);
        if (numDevices == 0)
            throw std::runtime_error("No CUDA capable devices found!");
        std::cout << "Found " << numDevices << " CUDA devices" << std::endl;

        // Initialize OptiX
        OPTIX_CHECK(optixInit());
        std::cout << "Successfully initialized OptiX. Hooray!" << std::endl;
    }

    // Logging callback for device context in case there is an error
    static void context_log_cb(unsigned int level,
                               const char* tag,
                               const char* message,
                               void*)
    {
        fprintf(stderr, "[%2d][%12s]: %s\n", (int)level, tag, message);
    }

    // Creates and configures OptiX device context (for now only for the primary GPU)
    void Renderer::createContext()
    {
        const int deviceID = 0;
        CUDA_CHECK(SetDevice(deviceID));
        CUDA_CHECK(StreamCreate(&stream));

        cudaGetDeviceProperties(&deviceProperties, deviceID);
        std::cout << "Running on device: " << deviceProperties.name << std::endl;

        CUresult  cuRes = cuCtxGetCurrent(&cudaContext);
        if (cuRes != CUDA_SUCCESS)
            fprintf(stderr, "Error querying current context: error code %d\n", cuRes);

        OPTIX_CHECK(optixDeviceContextCreate(cudaContext, 0, &optixContext));
        OPTIX_CHECK(optixDeviceContextSetLogCallback
        (optixContext, context_log_cb, nullptr, 4));
    }


    // Render loop
    void Renderer::render()
    {
        // First resize needs to be done before rendering
        if (tutorialPipeline->launchParams.frame.size.x == 0) return;

        tutorialPipeline->uploadLaunchParams();

        // Launch render pipeline
        OPTIX_CHECK(optixLaunch(/*! pipeline we're launching launch: */
            tutorialPipeline->pipeline, stream,
            /*! launch parameters and SBT */
            tutorialPipeline->launchParamsBuffer.d_pointer(),
            tutorialPipeline->launchParamsBuffer.sizeInBytes,
            &tutorialPipeline->sbt,
            /*! dimensions of the launch: */
            tutorialPipeline->launchParams.frame.size.x,
            tutorialPipeline->launchParams.frame.size.y,
            1
        ));


        // TODO: implement double buffering!!!
        // sync - make sure the frame is rendered before we download and
        // display (obviously, for a high-performance application you
        // want to use streams and double-buffering, but for this simple
        // example, this will have to do)
        CUDA_SYNC_CHECK();
    }

    void Renderer::updateCamera(const Camera& camera)
    {
        if (tutorialPipeline != nullptr)
        {
            renderCamera = camera;
            tutorialPipeline->launchParams.camera.position = camera.position;
            tutorialPipeline->launchParams.camera.direction = normalize(camera.target - camera.position);
            const float cosFovy = 0.66f;
            const float aspect = float(tutorialPipeline->launchParams.frame.size.x) / float(tutorialPipeline->launchParams.frame.size.y);
            tutorialPipeline->launchParams.camera.horizontal
                = cosFovy * aspect * normalize(cross(tutorialPipeline->launchParams.camera.direction,
                    camera.up));
            tutorialPipeline->launchParams.camera.vertical
                = cosFovy * normalize(cross(tutorialPipeline->launchParams.camera.horizontal,
                    tutorialPipeline->launchParams.camera.direction));
        }
    }

    void Renderer::writeToImage(std::string fileName, int resX, int resY, void* data)
    {
        stbi_write_png(fileName.c_str(), resX, resY, 4, data, resX * sizeof(uint32_t));
    }



    // Will allocate a `size * size` buffer on the GPU
    void Renderer::initDirectLightingTexture(int size)
    {
        directLightingTexture.resize(size * size * sizeof(uint32_t));
        directLightPipeline->launchParams.directLightingTexture.size = size;
        directLightPipeline->launchParams.directLightingTexture.colorBuffer = (uint32_t*)directLightingTexture.d_pointer();
    }


    void Renderer::calculateDirectLighting()
    {
        // Get lights data from scene
        directLightPipeline->launchParams.lights = scene.getLightsData().data();
        directLightPipeline->launchParams.stratifyResX = STRATIFIED_X_SIZE;
        directLightPipeline->launchParams.stratifyResY = STRATIFIED_Y_SIZE;
        directLightPipeline->uploadLaunchParams();

        // Launch direct lighting pipeline
        OPTIX_CHECK(optixLaunch(
            directLightPipeline->pipeline, stream,
            directLightPipeline->launchParamsBuffer.d_pointer(),
            directLightPipeline->launchParamsBuffer.sizeInBytes,
            &directLightPipeline->sbt,
            NUM_SAMPLES_LIGHT * scene.amountLights(),   // dimension X: the light we are currently sampling
            STRATIFIED_X_SIZE,                          // dimension Y: the x-coordinate of our stratified sample grid cell (on the light)
            STRATIFIED_Y_SIZE                           // dimension Z: the y-coordinate of our stratified sample grid cell (on the light)
            // dimension X * dimension Y * dimension Z CUDA threads will be spawned 
        ));

        CUDA_SYNC_CHECK();

        // Download resulting texture from GPU
        uint32_t* direct_lighting_result;
        directLightingTexture.download(direct_lighting_result,
            directLightPipeline->launchParams.directLightingTexture.size * directLightPipeline->launchParams.directLightingTexture.size);

        // Write the result to an image (for debugging purposes)
        writeToImage("direct_lighting_output.png", directLightPipeline->launchParams.directLightingTexture.size, directLightPipeline->launchParams.directLightingTexture.size, direct_lighting_result);
    }


    void Renderer::resize(const glm::ivec2& newSize)
    {
        // If window minimized
        if (newSize.x == 0 | newSize.y == 0) return;

        // Resize CUDA frame buffer
        colorBuffer.resize(newSize.x * newSize.y * sizeof(uint32_t));
    
        // Update launch parameters that are passed to OptiX launch
        tutorialPipeline->launchParams.frame.size = newSize;
        tutorialPipeline->launchParams.frame.colorBuffer = (uint32_t*)colorBuffer.d_pointer();

        // Reset camera, aspect may have changed
        updateCamera(renderCamera);
    }

    // Copy rendered color buffer from device to host memory for display
    void Renderer::downloadPixels(uint32_t h_pixels[])
    {
        colorBuffer.download(h_pixels,
            tutorialPipeline->launchParams.frame.size.x * tutorialPipeline->launchParams.frame.size.y);
    }
}