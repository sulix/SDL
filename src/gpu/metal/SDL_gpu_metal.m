/*
  Simple DirectMedia Layer
  Copyright (C) 1997-2024 Sam Lantinga <slouken@libsdl.org>

  This software is provided 'as-is', without any express or implied
  warranty.  In no event will the authors be held liable for any damages
  arising from the use of this software.

  Permission is granted to anyone to use this software for any purpose,
  including commercial applications, and to alter it and redistribute it
  freely, subject to the following restrictions:

  1. The origin of this software must not be misrepresented; you must not
     claim that you wrote the original software. If you use this software
     in a product, an acknowledgment in the product documentation would be
     appreciated but is not required.
  2. Altered source versions must be plainly marked as such, and must not be
     misrepresented as being the original software.
  3. This notice may not be removed or altered from any source distribution.
*/

#include "SDL_internal.h"

#if SDL_GPU_METAL

#include <Metal/Metal.h>
#include <QuartzCore/CoreAnimation.h>

#include "../SDL_sysgpu.h"

/* Defines */

#define METAL_MAX_BUFFER_COUNT      31
#define WINDOW_PROPERTY_DATA        "SDL_GpuMetalWindowPropertyData"
#define SDL_GPU_SHADERSTAGE_COMPUTE 2

#define EXPAND_ARRAY_IF_NEEDED(arr, elementType, newCount, capacity, newCapacity) \
    if (newCount >= capacity) {                                                   \
        capacity = newCapacity;                                                   \
        arr = (elementType *)SDL_realloc(                                         \
            arr,                                                                  \
            sizeof(elementType) * capacity);                                      \
    }

#define TRACK_RESOURCE(resource, type, array, count, capacity) \
    Uint32 i;                                                  \
                                                               \
    for (i = 0; i < commandBuffer->count; i += 1) {            \
        if (commandBuffer->array[i] == resource) {             \
            return;                                            \
        }                                                      \
    }                                                          \
                                                               \
    if (commandBuffer->count == commandBuffer->capacity) {     \
        commandBuffer->capacity += 1;                          \
        commandBuffer->array = SDL_realloc(                    \
            commandBuffer->array,                              \
            commandBuffer->capacity * sizeof(type));           \
    }                                                          \
    commandBuffer->array[commandBuffer->count] = resource;     \
    commandBuffer->count += 1;                                 \
    SDL_AtomicIncRef(&resource->referenceCount);

/* Blit Shaders */

static const char *FullscreenVertexShader =
    "using namespace metal;\n"
    "struct VertexToPixel { float4 position [[position]]; float2 texcoord; };\n"
    "vertex VertexToPixel vs_main(uint vI [[vertex_id]]) {\n"
    "   float2 inTexcoord = float2((vI << 1) & 2, vI & 2);\n"
    "   VertexToPixel out;\n"
    "   out.position = float4(inTexcoord * float2(2.0f, -2.0f) + float2(-1.0f, 1.0f), 0.0f, 1.0f);\n"
    "   out.texcoord = inTexcoord;\n"
    "   return out;\n"
    "}";

static const char *BlitFrom2DFragmentShader =
    "using namespace metal;\n"
    "struct VertexToPixel { float4 position [[position]]; float2 texcoord; };\n"
    "fragment float4 fs_main(\n"
    "   VertexToPixel input [[stage_in]],\n"
    "   texture2d<float> srcTexture [[texture(0)]],\n"
    "   sampler srcSampler [[sampler(0)]]) {\n"
    "   return srcTexture.sample(srcSampler, input.texcoord);\n"
    "}";

/* Forward Declarations */

static void METAL_Wait(SDL_GpuRenderer *driverData);
static void METAL_UnclaimWindow(
    SDL_GpuRenderer *driverData,
    SDL_Window *window);
static void METAL_INTERNAL_DestroyBlitResources(SDL_GpuRenderer *driverData);

/* Conversions */

static MTLPixelFormat SDLToMetal_SurfaceFormat[] = {
    MTLPixelFormatRGBA8Unorm,   /* R8G8B8A8 */
    MTLPixelFormatBGRA8Unorm,   /* B8G8R8A8 */
    MTLPixelFormatB5G6R5Unorm,  /* B5G6R5 */
    MTLPixelFormatBGR5A1Unorm,  /* B5G5R5A1 */
    MTLPixelFormatABGR4Unorm,   /* B4G4R4A4 */
    MTLPixelFormatRGB10A2Unorm, /* A2R10G10B10 */
    MTLPixelFormatRG16Unorm,    /* R16G16 */
    MTLPixelFormatRGBA16Unorm,  /* R16G16B16A16 */
    MTLPixelFormatR8Unorm,      /* R8 */
    MTLPixelFormatA8Unorm,      /* A8 */
#ifdef SDL_PLATFORM_MACOS
    MTLPixelFormatBC1_RGBA,      /* BC1 */
    MTLPixelFormatBC2_RGBA,      /* BC2 */
    MTLPixelFormatBC3_RGBA,      /* BC3 */
    MTLPixelFormatBC7_RGBAUnorm, /* BC7 */
#else
    MTLPixelFormatInvalid, /* BC1 */
    MTLPixelFormatInvalid, /* BC2 */
    MTLPixelFormatInvalid, /* BC3 */
    MTLPixelFormatInvalid, /* BC7 */
#endif
    MTLPixelFormatRG8Snorm,        /* R8G8_SNORM */
    MTLPixelFormatRGBA8Snorm,      /* R8G8B8A8_SNORM */
    MTLPixelFormatR16Float,        /* R16_SFLOAT */
    MTLPixelFormatRG16Float,       /* R16G16_SFLOAT */
    MTLPixelFormatRGBA16Float,     /* R16G16B16A16_SFLOAT */
    MTLPixelFormatR32Float,        /* R32_SFLOAT */
    MTLPixelFormatRG32Float,       /* R32G32_SFLOAT */
    MTLPixelFormatRGBA32Float,     /* R32G32B32A32_SFLOAT */
    MTLPixelFormatR8Uint,          /* R8_UINT */
    MTLPixelFormatRG8Uint,         /* R8G8_UINT */
    MTLPixelFormatRGBA8Uint,       /* R8G8B8A8_UINT */
    MTLPixelFormatR16Uint,         /* R16_UINT */
    MTLPixelFormatRG16Uint,        /* R16G16_UINT */
    MTLPixelFormatRGBA16Uint,      /* R16G16B16A16_UINT */
    MTLPixelFormatRGBA8Unorm_sRGB, /* R8G8B8A8_SRGB*/
    MTLPixelFormatBGRA8Unorm_sRGB, /* B8G8R8A8_SRGB */
#ifdef SDL_PLATFORM_MACOS
    MTLPixelFormatBC3_RGBA_sRGB,      /* BC3_SRGB */
    MTLPixelFormatBC7_RGBAUnorm_sRGB, /* BC7_SRGB */
#else
    MTLPixelFormatInvalid, /* BC3_SRGB */
    MTLPixelFormatInvalid, /* BC7_SRGB */
#endif
    MTLPixelFormatDepth16Unorm, /* D16_UNORM */
#ifdef SDL_PLATFORM_MACOS
    MTLPixelFormatDepth24Unorm_Stencil8, /* D24_UNORM */
#else
    MTLPixelFormatInvalid, /* D24_UNORM */
#endif
    MTLPixelFormatDepth32Float, /* D32_SFLOAT */
#ifdef SDL_PLATFORM_MACOS
    MTLPixelFormatDepth24Unorm_Stencil8, /* D24_UNORM_S8_UINT */
#else
    MTLPixelFormatInvalid, /* D24_UNORM_S8_UINT */
#endif
    MTLPixelFormatDepth32Float_Stencil8, /* D32_SFLOAT_S8_UINT */
};

static MTLVertexFormat SDLToMetal_VertexFormat[] = {
    MTLVertexFormatUInt,             /* UINT */
    MTLVertexFormatFloat,            /* FLOAT */
    MTLVertexFormatFloat2,           /* VECTOR2 */
    MTLVertexFormatFloat3,           /* VECTOR3 */
    MTLVertexFormatFloat4,           /* VECTOR4 */
    MTLVertexFormatUChar4Normalized, /* COLOR */
    MTLVertexFormatUChar4,           /* BYTE4 */
    MTLVertexFormatShort2,           /* SHORT2 */
    MTLVertexFormatShort4,           /* SHORT4 */
    MTLVertexFormatShort2Normalized, /* NORMALIZEDSHORT2 */
    MTLVertexFormatShort4Normalized, /* NORMALIZEDSHORT4 */
    MTLVertexFormatHalf2,            /* HALFVECTOR2 */
    MTLVertexFormatHalf4,            /* HALFVECTOR4 */
};

static MTLIndexType SDLToMetal_IndexType[] = {
    MTLIndexTypeUInt16, /* 16BIT */
    MTLIndexTypeUInt32, /* 32BIT */
};

static MTLPrimitiveType SDLToMetal_PrimitiveType[] = {
    MTLPrimitiveTypePoint,        /* POINTLIST */
    MTLPrimitiveTypeLine,         /* LINELIST */
    MTLPrimitiveTypeLineStrip,    /* LINESTRIP */
    MTLPrimitiveTypeTriangle,     /* TRIANGLELIST */
    MTLPrimitiveTypeTriangleStrip /* TRIANGLESTRIP */
};

static MTLTriangleFillMode SDLToMetal_PolygonMode[] = {
    MTLTriangleFillModeFill,  /* FILL */
    MTLTriangleFillModeLines, /* LINE */
};

static MTLCullMode SDLToMetal_CullMode[] = {
    MTLCullModeNone,  /* NONE */
    MTLCullModeFront, /* FRONT */
    MTLCullModeBack,  /* BACK */
};

static MTLWinding SDLToMetal_FrontFace[] = {
    MTLWindingCounterClockwise, /* COUNTER_CLOCKWISE */
    MTLWindingClockwise,        /* CLOCKWISE */
};

static MTLBlendFactor SDLToMetal_BlendFactor[] = {
    MTLBlendFactorZero,                     /* ZERO */
    MTLBlendFactorOne,                      /* ONE */
    MTLBlendFactorSourceColor,              /* SRC_COLOR */
    MTLBlendFactorOneMinusSourceColor,      /* ONE_MINUS_SRC_COLOR */
    MTLBlendFactorDestinationColor,         /* DST_COLOR */
    MTLBlendFactorOneMinusDestinationColor, /* ONE_MINUS_DST_COLOR */
    MTLBlendFactorSourceAlpha,              /* SRC_ALPHA */
    MTLBlendFactorOneMinusSourceAlpha,      /* ONE_MINUS_SRC_ALPHA */
    MTLBlendFactorDestinationAlpha,         /* DST_ALPHA */
    MTLBlendFactorOneMinusDestinationAlpha, /* ONE_MINUS_DST_ALPHA */
    MTLBlendFactorBlendColor,               /* CONSTANT_COLOR */
    MTLBlendFactorOneMinusBlendColor,       /* ONE_MINUS_CONSTANT_COLOR */
    MTLBlendFactorSourceAlphaSaturated,     /* SRC_ALPHA_SATURATE */
};

static MTLBlendOperation SDLToMetal_BlendOp[] = {
    MTLBlendOperationAdd,             /* ADD */
    MTLBlendOperationSubtract,        /* SUBTRACT */
    MTLBlendOperationReverseSubtract, /* REVERSE_SUBTRACT */
    MTLBlendOperationMin,             /* MIN */
    MTLBlendOperationMax,             /* MAX */
};

static MTLCompareFunction SDLToMetal_CompareOp[] = {
    MTLCompareFunctionNever,        /* NEVER */
    MTLCompareFunctionLess,         /* LESS */
    MTLCompareFunctionEqual,        /* EQUAL */
    MTLCompareFunctionLessEqual,    /* LESS_OR_EQUAL */
    MTLCompareFunctionGreater,      /* GREATER */
    MTLCompareFunctionNotEqual,     /* NOT_EQUAL */
    MTLCompareFunctionGreaterEqual, /* GREATER_OR_EQUAL */
    MTLCompareFunctionAlways,       /* ALWAYS */
};

static MTLStencilOperation SDLToMetal_StencilOp[] = {
    MTLStencilOperationKeep,           /* KEEP */
    MTLStencilOperationZero,           /* ZERO */
    MTLStencilOperationReplace,        /* REPLACE */
    MTLStencilOperationIncrementClamp, /* INCREMENT_AND_CLAMP */
    MTLStencilOperationDecrementClamp, /* DECREMENT_AND_CLAMP */
    MTLStencilOperationInvert,         /* INVERT */
    MTLStencilOperationIncrementWrap,  /* INCREMENT_AND_WRAP */
    MTLStencilOperationDecrementWrap,  /* DECREMENT_AND_WRAP */
};

static MTLSamplerAddressMode SDLToMetal_SamplerAddressMode[] = {
    MTLSamplerAddressModeRepeat,       /* REPEAT */
    MTLSamplerAddressModeMirrorRepeat, /* MIRRORED_REPEAT */
    MTLSamplerAddressModeClampToEdge   /* CLAMP_TO_EDGE */
};

static MTLSamplerMinMagFilter SDLToMetal_MinMagFilter[] = {
    MTLSamplerMinMagFilterNearest, /* NEAREST */
    MTLSamplerMinMagFilterLinear,  /* LINEAR */
};

static MTLSamplerMipFilter SDLToMetal_MipFilter[] = {
    MTLSamplerMipFilterNearest, /* NEAREST */
    MTLSamplerMipFilterLinear,  /* LINEAR */
};

static MTLLoadAction SDLToMetal_LoadOp[] = {
    MTLLoadActionLoad,     /* LOAD */
    MTLLoadActionClear,    /* CLEAR */
    MTLLoadActionDontCare, /* DONT_CARE */
};

static MTLVertexStepFunction SDLToMetal_StepFunction[] = {
    MTLVertexStepFunctionPerVertex,
    MTLVertexStepFunctionPerInstance,
};

static NSUInteger SDLToMetal_SampleCount[] = {
    1, /* SDL_GPU_SAMPLECOUNT_1 */
    2, /* SDL_GPU_SAMPLECOUNT_2 */
    4, /* SDL_GPU_SAMPLECOUNT_4 */
    8  /* SDL_GPU_SAMPLECOUNT_8 */
};

static MTLTextureType SDLToMetal_TextureType[] = {
    MTLTextureType2D,      /* SDL_GPU_TEXTURETYPE_2D */
    MTLTextureType2DArray, /* SDL_GPU_TEXTURETYPE_2D_ARRAY */
    MTLTextureType3D,      /* SDL_GPU_TEXTURETYPE_3D */
    MTLTextureTypeCube     /* SDL_GPU_TEXTURETYPE_CUBE */
};

static SDL_GpuTextureFormat SwapchainCompositionToFormat[] = {
    SDL_GPU_TEXTUREFORMAT_B8G8R8A8,            /* SDR */
    SDL_GPU_TEXTUREFORMAT_B8G8R8A8_SRGB,       /* SDR_LINEAR */
    SDL_GPU_TEXTUREFORMAT_R16G16B16A16_SFLOAT, /* HDR_EXTENDED_LINEAR */
    SDL_GPU_TEXTUREFORMAT_R10G10B10A2,         /* HDR10_ST2048 */
};

static CFStringRef SwapchainCompositionToColorSpace[4]; /* initialized on device creation */

static MTLStoreAction SDLToMetal_StoreOp(
    SDL_GpuStoreOp storeOp,
    Uint8 isMultisample)
{
    if (isMultisample) {
        if (storeOp == SDL_GPU_STOREOP_STORE) {
            return MTLStoreActionStoreAndMultisampleResolve;
        } else {
            return MTLStoreActionMultisampleResolve;
        }
    } else {
        if (storeOp == SDL_GPU_STOREOP_STORE) {
            return MTLStoreActionStore;
        } else {
            return MTLStoreActionDontCare;
        }
    }
};

static MTLColorWriteMask SDLToMetal_ColorWriteMask(
    SDL_GpuColorComponentFlagBits mask)
{
    MTLColorWriteMask result = 0;
    if (mask & SDL_GPU_COLORCOMPONENT_R_BIT) {
        result |= MTLColorWriteMaskRed;
    }
    if (mask & SDL_GPU_COLORCOMPONENT_G_BIT) {
        result |= MTLColorWriteMaskGreen;
    }
    if (mask & SDL_GPU_COLORCOMPONENT_B_BIT) {
        result |= MTLColorWriteMaskBlue;
    }
    if (mask & SDL_GPU_COLORCOMPONENT_A_BIT) {
        result |= MTLColorWriteMaskAlpha;
    }
    return result;
}

/* Structs */

typedef struct MetalTexture
{
    id<MTLTexture> handle;
    id<MTLTexture> msaaHandle;
    SDL_AtomicInt referenceCount;
} MetalTexture;

typedef struct MetalTextureContainer
{
    TextureCommonHeader header;

    MetalTexture *activeTexture;
    Uint8 canBeCycled;

    Uint32 textureCapacity;
    Uint32 textureCount;
    MetalTexture **textures;

    char *debugName;
} MetalTextureContainer;

typedef struct MetalFence
{
    SDL_AtomicInt complete;
} MetalFence;

typedef struct MetalWindowData
{
    SDL_Window *window;
    SDL_MetalView view;
    CAMetalLayer *layer;
    id<CAMetalDrawable> drawable;
    MetalTexture texture;
    MetalTextureContainer textureContainer;
} MetalWindowData;

typedef struct MetalShader
{
    id<MTLLibrary> library;
    id<MTLFunction> function;

    Uint32 samplerCount;
    Uint32 uniformBufferCount;
    Uint32 storageBufferCount;
    Uint32 storageTextureCount;
} MetalShader;

typedef struct MetalGraphicsPipeline
{
    id<MTLRenderPipelineState> handle;

    float blendConstants[4];
    Uint32 sampleMask;

    SDL_GpuRasterizerState rasterizerState;
    SDL_GpuPrimitiveType primitiveType;

    id<MTLDepthStencilState> depthStencilState;
    Uint32 stencilReference;

    Uint32 vertexSamplerCount;
    Uint32 vertexUniformBufferCount;
    Uint32 vertexStorageBufferCount;
    Uint32 vertexStorageTextureCount;

    Uint32 fragmentSamplerCount;
    Uint32 fragmentUniformBufferCount;
    Uint32 fragmentStorageBufferCount;
    Uint32 fragmentStorageTextureCount;
} MetalGraphicsPipeline;

typedef struct MetalComputePipeline
{
    id<MTLComputePipelineState> handle;
    Uint32 readOnlyStorageTextureCount;
    Uint32 readWriteStorageTextureCount;
    Uint32 readOnlyStorageBufferCount;
    Uint32 readWriteStorageBufferCount;
    Uint32 uniformBufferCount;
    Uint32 threadCountX;
    Uint32 threadCountY;
    Uint32 threadCountZ;
} MetalComputePipeline;

typedef struct MetalBuffer
{
    id<MTLBuffer> handle;
    SDL_AtomicInt referenceCount;
} MetalBuffer;

typedef struct MetalBufferContainer
{
    MetalBuffer *activeBuffer;
    Uint32 size;

    Uint32 bufferCapacity;
    Uint32 bufferCount;
    MetalBuffer **buffers;

    SDL_bool isPrivate;
    SDL_bool isWriteOnly;
    char *debugName;
} MetalBufferContainer;

typedef struct MetalUniformBuffer
{
    id<MTLBuffer> handle;
    Uint32 writeOffset;
    Uint32 drawOffset;
} MetalUniformBuffer;

typedef struct MetalRenderer MetalRenderer;

typedef struct MetalCommandBuffer
{
    CommandBufferCommonHeader common;
    MetalRenderer *renderer;

    /* Native Handle */
    id<MTLCommandBuffer> handle;

    /* Presentation */
    MetalWindowData **windowDatas;
    Uint32 windowDataCount;
    Uint32 windowDataCapacity;

    /* Render Pass */
    id<MTLRenderCommandEncoder> renderEncoder;
    MetalGraphicsPipeline *graphicsPipeline;
    MetalBuffer *indexBuffer;
    Uint32 indexBufferOffset;
    SDL_GpuIndexElementSize indexElementSize;

    /* Copy Pass */
    id<MTLBlitCommandEncoder> blitEncoder;

    /* Compute Pass */
    id<MTLComputeCommandEncoder> computeEncoder;
    MetalComputePipeline *computePipeline;

    /* Resource slot state */
    SDL_bool needVertexSamplerBind;
    SDL_bool needVertexStorageTextureBind;
    SDL_bool needVertexStorageBufferBind;
    SDL_bool needVertexUniformBind;

    SDL_bool needFragmentSamplerBind;
    SDL_bool needFragmentStorageTextureBind;
    SDL_bool needFragmentStorageBufferBind;
    SDL_bool needFragmentUniformBind;

    SDL_bool needComputeTextureBind;
    SDL_bool needComputeBufferBind;
    SDL_bool needComputeUniformBind;

    id<MTLSamplerState> vertexSamplers[MAX_TEXTURE_SAMPLERS_PER_STAGE];
    id<MTLTexture> vertexTextures[MAX_TEXTURE_SAMPLERS_PER_STAGE];
    id<MTLTexture> vertexStorageTextures[MAX_STORAGE_TEXTURES_PER_STAGE];
    id<MTLBuffer> vertexStorageBuffers[MAX_STORAGE_BUFFERS_PER_STAGE];

    id<MTLSamplerState> fragmentSamplers[MAX_TEXTURE_SAMPLERS_PER_STAGE];
    id<MTLTexture> fragmentTextures[MAX_TEXTURE_SAMPLERS_PER_STAGE];
    id<MTLTexture> fragmentStorageTextures[MAX_STORAGE_TEXTURES_PER_STAGE];
    id<MTLBuffer> fragmentStorageBuffers[MAX_STORAGE_BUFFERS_PER_STAGE];

    id<MTLTexture> computeReadOnlyTextures[MAX_STORAGE_TEXTURES_PER_STAGE];
    id<MTLBuffer> computeReadOnlyBuffers[MAX_STORAGE_BUFFERS_PER_STAGE];
    id<MTLTexture> computeReadWriteTextures[MAX_COMPUTE_WRITE_TEXTURES];
    id<MTLBuffer> computeReadWriteBuffers[MAX_COMPUTE_WRITE_BUFFERS];

    /* Uniform buffers */
    MetalUniformBuffer *vertexUniformBuffers[MAX_UNIFORM_BUFFERS_PER_STAGE];
    MetalUniformBuffer *fragmentUniformBuffers[MAX_UNIFORM_BUFFERS_PER_STAGE];
    MetalUniformBuffer *computeUniformBuffers[MAX_UNIFORM_BUFFERS_PER_STAGE];

    MetalUniformBuffer **usedUniformBuffers;
    Uint32 usedUniformBufferCount;
    Uint32 usedUniformBufferCapacity;

    /* Fences */
    MetalFence *fence;
    Uint8 autoReleaseFence;

    /* Reference Counting */
    MetalBuffer **usedBuffers;
    Uint32 usedBufferCount;
    Uint32 usedBufferCapacity;

    MetalTexture **usedTextures;
    Uint32 usedTextureCount;
    Uint32 usedTextureCapacity;
} MetalCommandBuffer;

typedef struct MetalSampler
{
    id<MTLSamplerState> handle;
} MetalSampler;

typedef struct BlitPipeline
{
    SDL_GpuGraphicsPipeline *pipeline;
    SDL_GpuTextureFormat format;
} BlitPipeline;

struct MetalRenderer
{
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;

    SDL_bool debugMode;

    MetalWindowData **claimedWindows;
    Uint32 claimedWindowCount;
    Uint32 claimedWindowCapacity;

    MetalCommandBuffer **availableCommandBuffers;
    Uint32 availableCommandBufferCount;
    Uint32 availableCommandBufferCapacity;

    MetalCommandBuffer **submittedCommandBuffers;
    Uint32 submittedCommandBufferCount;
    Uint32 submittedCommandBufferCapacity;

    MetalFence **availableFences;
    Uint32 availableFenceCount;
    Uint32 availableFenceCapacity;

    MetalUniformBuffer **uniformBufferPool;
    Uint32 uniformBufferPoolCount;
    Uint32 uniformBufferPoolCapacity;

    MetalBufferContainer **bufferContainersToDestroy;
    Uint32 bufferContainersToDestroyCount;
    Uint32 bufferContainersToDestroyCapacity;

    MetalTextureContainer **textureContainersToDestroy;
    Uint32 textureContainersToDestroyCount;
    Uint32 textureContainersToDestroyCapacity;

    /* Blit */
    SDL_GpuShader *fullscreenVertexShader;
    SDL_GpuShader *blitFrom2DPixelShader;
    SDL_GpuGraphicsPipeline *blitFrom2DPipeline;
    SDL_GpuSampler *blitNearestSampler;
    SDL_GpuSampler *blitLinearSampler;

    BlitPipeline *blitPipelines;
    Uint32 blitPipelineCount;
    Uint32 blitPipelineCapacity;

    /* Mutexes */
    SDL_Mutex *submitLock;
    SDL_Mutex *acquireCommandBufferLock;
    SDL_Mutex *acquireUniformBufferLock;
    SDL_Mutex *disposeLock;
    SDL_Mutex *fenceLock;
    SDL_Mutex *windowLock;
};

/* Helper Functions */

static Uint32 METAL_INTERNAL_GetVertexBufferIndex(Uint32 binding)
{
    return METAL_MAX_BUFFER_COUNT - 1 - binding;
}

/* FIXME: This should be moved into SDL_sysgpu.h */
static inline Uint32 METAL_INTERNAL_NextHighestAlignment(
    Uint32 n,
    Uint32 align)
{
    return align * ((n + align - 1) / align);
}

/* Quit */

static void METAL_DestroyDevice(SDL_GpuDevice *device)
{
    MetalRenderer *renderer = (MetalRenderer *)device->driverData;

    /* Flush any remaining GPU work... */
    METAL_Wait(device->driverData);

    /* Release the window data */
    for (Sint32 i = renderer->claimedWindowCount - 1; i >= 0; i -= 1) {
        METAL_UnclaimWindow(device->driverData, renderer->claimedWindows[i]->window);
    }
    SDL_free(renderer->claimedWindows);

    /* Release the blit resources */
    METAL_INTERNAL_DestroyBlitResources(device->driverData);

    /* Release uniform buffers */
    for (Uint32 i = 0; i < renderer->uniformBufferPoolCount; i += 1) {
        renderer->uniformBufferPool[i]->handle = nil;
        SDL_free(renderer->uniformBufferPool[i]);
    }
    SDL_free(renderer->uniformBufferPool);

    /* Release destroyed resource lists */
    SDL_free(renderer->bufferContainersToDestroy);
    SDL_free(renderer->textureContainersToDestroy);

    /* Release command buffer infrastructure */
    for (Uint32 i = 0; i < renderer->availableCommandBufferCount; i += 1) {
        MetalCommandBuffer *commandBuffer = renderer->availableCommandBuffers[i];
        SDL_free(commandBuffer->usedBuffers);
        SDL_free(commandBuffer->usedTextures);
        SDL_free(commandBuffer->usedUniformBuffers);
        SDL_free(commandBuffer->windowDatas);
        SDL_free(commandBuffer);
    }
    SDL_free(renderer->availableCommandBuffers);
    SDL_free(renderer->submittedCommandBuffers);

    /* Release fence infrastructure */
    for (Uint32 i = 0; i < renderer->availableFenceCount; i += 1) {
        SDL_free(renderer->availableFences[i]);
    }
    SDL_free(renderer->availableFences);

    /* Release the mutexes */
    SDL_DestroyMutex(renderer->submitLock);
    SDL_DestroyMutex(renderer->acquireCommandBufferLock);
    SDL_DestroyMutex(renderer->acquireUniformBufferLock);
    SDL_DestroyMutex(renderer->disposeLock);
    SDL_DestroyMutex(renderer->fenceLock);
    SDL_DestroyMutex(renderer->windowLock);

    /* Release the command queue */
    renderer->queue = nil;

    /* Free the primary structures */
    SDL_free(renderer);
    SDL_free(device);
}

/* Resource tracking */

static void METAL_INTERNAL_TrackBuffer(
    MetalCommandBuffer *commandBuffer,
    MetalBuffer *buffer)
{
    TRACK_RESOURCE(
        buffer,
        MetalBuffer *,
        usedBuffers,
        usedBufferCount,
        usedBufferCapacity);
}

static void METAL_INTERNAL_TrackTexture(
    MetalCommandBuffer *commandBuffer,
    MetalTexture *texture)
{
    TRACK_RESOURCE(
        texture,
        MetalTexture *,
        usedTextures,
        usedTextureCount,
        usedTextureCapacity);
}

static void METAL_INTERNAL_TrackUniformBuffer(
    MetalCommandBuffer *commandBuffer,
    MetalUniformBuffer *uniformBuffer)
{
    Uint32 i;
    for (i = 0; i < commandBuffer->usedUniformBufferCount; i += 1) {
        if (commandBuffer->usedUniformBuffers[i] == uniformBuffer) {
            return;
        }
    }

    if (commandBuffer->usedUniformBufferCount == commandBuffer->usedUniformBufferCapacity) {
        commandBuffer->usedUniformBufferCapacity += 1;
        commandBuffer->usedUniformBuffers = SDL_realloc(
            commandBuffer->usedUniformBuffers,
            commandBuffer->usedUniformBufferCapacity * sizeof(MetalUniformBuffer *));
    }

    commandBuffer->usedUniformBuffers[commandBuffer->usedUniformBufferCount] = uniformBuffer;
    commandBuffer->usedUniformBufferCount += 1;
}

/* Shader Compilation */

typedef struct MetalLibraryFunction
{
    id<MTLLibrary> library;
    id<MTLFunction> function;
} MetalLibraryFunction;

/* This function assumes that it's called from within an autorelease pool */
static MetalLibraryFunction METAL_INTERNAL_CompileShader(
    MetalRenderer *renderer,
    SDL_GpuShaderFormat format,
    const Uint8 *code,
    size_t codeSize,
    const char *entryPointName)
{
    MetalLibraryFunction libraryFunction = { nil, nil };
    id<MTLLibrary> library;
    NSError *error;
    dispatch_data_t data;
    id<MTLFunction> function;

    if (format == SDL_GPU_SHADERFORMAT_MSL) {
        library = [renderer->device
            newLibraryWithSource:@((const char *)code)
                         options:nil
                           error:&error];
    } else if (format == SDL_GPU_SHADERFORMAT_METALLIB) {
        data = dispatch_data_create(
            code,
            codeSize,
            dispatch_get_global_queue(0, 0),
            ^{ /* do nothing */ });
        library = [renderer->device newLibraryWithData:data error:&error];
    } else {
        SDL_assert(!"SDL_gpu.c should have already validated this!");
        return libraryFunction;
    }

    if (library == nil) {
        SDL_LogError(
            SDL_LOG_CATEGORY_GPU,
            "Creating MTLLibrary failed: %s",
            [[error description] cStringUsingEncoding:[NSString defaultCStringEncoding]]);
        return libraryFunction;
    } else if (error != nil) {
        SDL_LogWarn(
            SDL_LOG_CATEGORY_GPU,
            "Creating MTLLibrary failed: %s",
            [[error description] cStringUsingEncoding:[NSString defaultCStringEncoding]]);
    }

    function = [library newFunctionWithName:@(entryPointName)];
    if (function == nil) {
        SDL_LogError(
            SDL_LOG_CATEGORY_GPU,
            "Creating MTLFunction failed");
        return libraryFunction;
    }

    libraryFunction.library = library;
    libraryFunction.function = function;
    return libraryFunction;
}

/* Disposal */

static void METAL_INTERNAL_DestroyTextureContainer(
    MetalTextureContainer *container)
{
    for (Uint32 i = 0; i < container->textureCount; i += 1) {
        container->textures[i]->handle = nil;
        container->textures[i]->msaaHandle = nil;
        SDL_free(container->textures[i]);
    }
    if (container->debugName != NULL) {
        SDL_free(container->debugName);
    }
    SDL_free(container->textures);
    SDL_free(container);
}

static void METAL_ReleaseTexture(
    SDL_GpuRenderer *driverData,
    SDL_GpuTexture *texture)
{
    MetalRenderer *renderer = (MetalRenderer *)driverData;
    MetalTextureContainer *container = (MetalTextureContainer *)texture;

    SDL_LockMutex(renderer->disposeLock);

    EXPAND_ARRAY_IF_NEEDED(
        renderer->textureContainersToDestroy,
        MetalTextureContainer *,
        renderer->textureContainersToDestroyCount + 1,
        renderer->textureContainersToDestroyCapacity,
        renderer->textureContainersToDestroyCapacity + 1);

    renderer->textureContainersToDestroy[renderer->textureContainersToDestroyCount] = container;
    renderer->textureContainersToDestroyCount += 1;

    SDL_UnlockMutex(renderer->disposeLock);
}

static void METAL_ReleaseSampler(
    SDL_GpuRenderer *driverData,
    SDL_GpuSampler *sampler)
{
    @autoreleasepool {
        MetalSampler *metalSampler = (MetalSampler *)sampler;
        metalSampler->handle = nil;
        SDL_free(metalSampler);
    }
}

static void METAL_INTERNAL_DestroyBufferContainer(
    MetalBufferContainer *container)
{
    for (Uint32 i = 0; i < container->bufferCount; i += 1) {
        container->buffers[i]->handle = nil;
        SDL_free(container->buffers[i]);
    }
    if (container->debugName != NULL) {
        SDL_free(container->debugName);
    }
    SDL_free(container->buffers);
    SDL_free(container);
}

static void METAL_ReleaseBuffer(
    SDL_GpuRenderer *driverData,
    SDL_GpuBuffer *buffer)
{
    MetalRenderer *renderer = (MetalRenderer *)driverData;
    MetalBufferContainer *container = (MetalBufferContainer *)buffer;

    SDL_LockMutex(renderer->disposeLock);

    EXPAND_ARRAY_IF_NEEDED(
        renderer->bufferContainersToDestroy,
        MetalBufferContainer *,
        renderer->bufferContainersToDestroyCount + 1,
        renderer->bufferContainersToDestroyCapacity,
        renderer->bufferContainersToDestroyCapacity + 1);

    renderer->bufferContainersToDestroy[renderer->bufferContainersToDestroyCount] = container;
    renderer->bufferContainersToDestroyCount += 1;

    SDL_UnlockMutex(renderer->disposeLock);
}

static void METAL_ReleaseTransferBuffer(
    SDL_GpuRenderer *driverData,
    SDL_GpuTransferBuffer *transferBuffer)
{
    METAL_ReleaseBuffer(
        driverData,
        (SDL_GpuBuffer *)transferBuffer);
}

static void METAL_ReleaseShader(
    SDL_GpuRenderer *driverData,
    SDL_GpuShader *shader)
{
    @autoreleasepool {
        MetalShader *metalShader = (MetalShader *)shader;
        metalShader->function = nil;
        metalShader->library = nil;
        SDL_free(metalShader);
    }
}

static void METAL_ReleaseComputePipeline(
    SDL_GpuRenderer *driverData,
    SDL_GpuComputePipeline *computePipeline)
{
    @autoreleasepool {
        MetalComputePipeline *metalComputePipeline = (MetalComputePipeline *)computePipeline;
        metalComputePipeline->handle = nil;
        SDL_free(metalComputePipeline);
    }
}

static void METAL_ReleaseGraphicsPipeline(
    SDL_GpuRenderer *driverData,
    SDL_GpuGraphicsPipeline *graphicsPipeline)
{
    @autoreleasepool {
        MetalGraphicsPipeline *metalGraphicsPipeline = (MetalGraphicsPipeline *)graphicsPipeline;
        metalGraphicsPipeline->handle = nil;
        metalGraphicsPipeline->depthStencilState = nil;
        SDL_free(metalGraphicsPipeline);
    }
}

/* Pipeline Creation */

static SDL_GpuComputePipeline *METAL_CreateComputePipeline(
    SDL_GpuRenderer *driverData,
    SDL_GpuComputePipelineCreateInfo *pipelineCreateInfo)
{
    @autoreleasepool {
        MetalRenderer *renderer = (MetalRenderer *)driverData;
        MetalLibraryFunction libraryFunction;
        id<MTLComputePipelineState> handle;
        MetalComputePipeline *pipeline;
        NSError *error;

        libraryFunction = METAL_INTERNAL_CompileShader(
            renderer,
            pipelineCreateInfo->format,
            pipelineCreateInfo->code,
            pipelineCreateInfo->codeSize,
            pipelineCreateInfo->entryPointName);

        if (libraryFunction.library == nil || libraryFunction.function == nil) {
            return NULL;
        }

        handle = [renderer->device newComputePipelineStateWithFunction:libraryFunction.function error:&error];
        if (error != NULL) {
            SDL_LogError(
                SDL_LOG_CATEGORY_GPU,
                "Creating compute pipeline failed: %s", [[error description] UTF8String]);
            return NULL;
        }

        pipeline = SDL_malloc(sizeof(MetalComputePipeline));
        pipeline->handle = handle;
        pipeline->readOnlyStorageTextureCount = pipelineCreateInfo->readOnlyStorageTextureCount;
        pipeline->readWriteStorageTextureCount = pipelineCreateInfo->readWriteStorageTextureCount;
        pipeline->readOnlyStorageBufferCount = pipelineCreateInfo->readOnlyStorageBufferCount;
        pipeline->readWriteStorageBufferCount = pipelineCreateInfo->readWriteStorageBufferCount;
        pipeline->uniformBufferCount = pipelineCreateInfo->uniformBufferCount;
        pipeline->threadCountX = pipelineCreateInfo->threadCountX;
        pipeline->threadCountY = pipelineCreateInfo->threadCountY;
        pipeline->threadCountZ = pipelineCreateInfo->threadCountZ;

        return (SDL_GpuComputePipeline *)pipeline;
    }
}

static SDL_GpuGraphicsPipeline *METAL_CreateGraphicsPipeline(
    SDL_GpuRenderer *driverData,
    SDL_GpuGraphicsPipelineCreateInfo *pipelineCreateInfo)
{
    @autoreleasepool {
        MetalRenderer *renderer = (MetalRenderer *)driverData;
        MetalShader *vertexShader = (MetalShader *)pipelineCreateInfo->vertexShader;
        MetalShader *fragmentShader = (MetalShader *)pipelineCreateInfo->fragmentShader;
        MTLRenderPipelineDescriptor *pipelineDescriptor;
        SDL_GpuColorAttachmentBlendState *blendState;
        MTLVertexDescriptor *vertexDescriptor;
        Uint32 binding;
        MTLDepthStencilDescriptor *depthStencilDescriptor;
        MTLStencilDescriptor *frontStencilDescriptor = NULL;
        MTLStencilDescriptor *backStencilDescriptor = NULL;
        id<MTLDepthStencilState> depthStencilState = nil;
        id<MTLRenderPipelineState> pipelineState = nil;
        NSError *error = NULL;
        MetalGraphicsPipeline *result = NULL;

        pipelineDescriptor = [MTLRenderPipelineDescriptor new];

        /* Blend */

        for (Uint32 i = 0; i < pipelineCreateInfo->attachmentInfo.colorAttachmentCount; i += 1) {
            blendState = &pipelineCreateInfo->attachmentInfo.colorAttachmentDescriptions[i].blendState;

            pipelineDescriptor.colorAttachments[i].pixelFormat = SDLToMetal_SurfaceFormat[pipelineCreateInfo->attachmentInfo.colorAttachmentDescriptions[i].format];
            pipelineDescriptor.colorAttachments[i].writeMask = SDLToMetal_ColorWriteMask(blendState->colorWriteMask);
            pipelineDescriptor.colorAttachments[i].blendingEnabled = blendState->blendEnable;
            pipelineDescriptor.colorAttachments[i].rgbBlendOperation = SDLToMetal_BlendOp[blendState->colorBlendOp];
            pipelineDescriptor.colorAttachments[i].alphaBlendOperation = SDLToMetal_BlendOp[blendState->alphaBlendOp];
            pipelineDescriptor.colorAttachments[i].sourceRGBBlendFactor = SDLToMetal_BlendFactor[blendState->srcColorBlendFactor];
            pipelineDescriptor.colorAttachments[i].sourceAlphaBlendFactor = SDLToMetal_BlendFactor[blendState->srcAlphaBlendFactor];
            pipelineDescriptor.colorAttachments[i].destinationRGBBlendFactor = SDLToMetal_BlendFactor[blendState->dstColorBlendFactor];
            pipelineDescriptor.colorAttachments[i].destinationAlphaBlendFactor = SDLToMetal_BlendFactor[blendState->dstAlphaBlendFactor];
        }

        /* Multisample */

        pipelineDescriptor.rasterSampleCount = SDLToMetal_SampleCount[pipelineCreateInfo->multisampleState.sampleCount];

        /* Depth Stencil */

        if (pipelineCreateInfo->attachmentInfo.hasDepthStencilAttachment) {
            pipelineDescriptor.depthAttachmentPixelFormat = SDLToMetal_SurfaceFormat[pipelineCreateInfo->attachmentInfo.depthStencilFormat];

            if (pipelineCreateInfo->depthStencilState.stencilTestEnable) {
                pipelineDescriptor.stencilAttachmentPixelFormat = SDLToMetal_SurfaceFormat[pipelineCreateInfo->attachmentInfo.depthStencilFormat];

                frontStencilDescriptor = [MTLStencilDescriptor new];
                frontStencilDescriptor.stencilCompareFunction = SDLToMetal_CompareOp[pipelineCreateInfo->depthStencilState.frontStencilState.compareOp];
                frontStencilDescriptor.stencilFailureOperation = SDLToMetal_StencilOp[pipelineCreateInfo->depthStencilState.frontStencilState.failOp];
                frontStencilDescriptor.depthStencilPassOperation = SDLToMetal_StencilOp[pipelineCreateInfo->depthStencilState.frontStencilState.passOp];
                frontStencilDescriptor.depthFailureOperation = SDLToMetal_StencilOp[pipelineCreateInfo->depthStencilState.frontStencilState.depthFailOp];
                frontStencilDescriptor.readMask = pipelineCreateInfo->depthStencilState.compareMask;
                frontStencilDescriptor.writeMask = pipelineCreateInfo->depthStencilState.writeMask;

                backStencilDescriptor = [MTLStencilDescriptor new];
                backStencilDescriptor.stencilCompareFunction = SDLToMetal_CompareOp[pipelineCreateInfo->depthStencilState.backStencilState.compareOp];
                backStencilDescriptor.stencilFailureOperation = SDLToMetal_StencilOp[pipelineCreateInfo->depthStencilState.backStencilState.failOp];
                backStencilDescriptor.depthStencilPassOperation = SDLToMetal_StencilOp[pipelineCreateInfo->depthStencilState.backStencilState.passOp];
                backStencilDescriptor.depthFailureOperation = SDLToMetal_StencilOp[pipelineCreateInfo->depthStencilState.backStencilState.depthFailOp];
                backStencilDescriptor.readMask = pipelineCreateInfo->depthStencilState.compareMask;
                backStencilDescriptor.writeMask = pipelineCreateInfo->depthStencilState.writeMask;
            }

            depthStencilDescriptor = [MTLDepthStencilDescriptor new];
            depthStencilDescriptor.depthCompareFunction = pipelineCreateInfo->depthStencilState.depthTestEnable ? SDLToMetal_CompareOp[pipelineCreateInfo->depthStencilState.compareOp] : MTLCompareFunctionAlways;
            depthStencilDescriptor.depthWriteEnabled = pipelineCreateInfo->depthStencilState.depthWriteEnable;
            depthStencilDescriptor.frontFaceStencil = frontStencilDescriptor;
            depthStencilDescriptor.backFaceStencil = backStencilDescriptor;

            depthStencilState = [renderer->device newDepthStencilStateWithDescriptor:depthStencilDescriptor];
        }

        /* Shaders */

        pipelineDescriptor.vertexFunction = vertexShader->function;
        pipelineDescriptor.fragmentFunction = fragmentShader->function;

        /* Vertex Descriptor */

        if (pipelineCreateInfo->vertexInputState.vertexBindingCount > 0) {
            vertexDescriptor = [MTLVertexDescriptor vertexDescriptor];

            for (Uint32 i = 0; i < pipelineCreateInfo->vertexInputState.vertexAttributeCount; i += 1) {
                Uint32 loc = pipelineCreateInfo->vertexInputState.vertexAttributes[i].location;
                vertexDescriptor.attributes[loc].format = SDLToMetal_VertexFormat[pipelineCreateInfo->vertexInputState.vertexAttributes[i].format];
                vertexDescriptor.attributes[loc].offset = pipelineCreateInfo->vertexInputState.vertexAttributes[i].offset;
                vertexDescriptor.attributes[loc].bufferIndex = METAL_INTERNAL_GetVertexBufferIndex(pipelineCreateInfo->vertexInputState.vertexAttributes[i].binding);
            }

            for (Uint32 i = 0; i < pipelineCreateInfo->vertexInputState.vertexBindingCount; i += 1) {
                binding = METAL_INTERNAL_GetVertexBufferIndex(pipelineCreateInfo->vertexInputState.vertexBindings[i].binding);
                vertexDescriptor.layouts[binding].stepFunction = SDLToMetal_StepFunction[pipelineCreateInfo->vertexInputState.vertexBindings[i].inputRate];
                vertexDescriptor.layouts[binding].stride = pipelineCreateInfo->vertexInputState.vertexBindings[i].stride;
            }

            pipelineDescriptor.vertexDescriptor = vertexDescriptor;
        }

        /* Create the graphics pipeline */

        pipelineState = [renderer->device newRenderPipelineStateWithDescriptor:pipelineDescriptor error:&error];
        if (error != NULL) {
            SDL_LogError(
                SDL_LOG_CATEGORY_GPU,
                "Creating render pipeline failed: %s", [[error description] UTF8String]);
            return NULL;
        }

        result = SDL_malloc(sizeof(MetalGraphicsPipeline));
        result->handle = pipelineState;
        result->blendConstants[0] = pipelineCreateInfo->blendConstants[0];
        result->blendConstants[1] = pipelineCreateInfo->blendConstants[1];
        result->blendConstants[2] = pipelineCreateInfo->blendConstants[2];
        result->blendConstants[3] = pipelineCreateInfo->blendConstants[3];
        result->sampleMask = pipelineCreateInfo->multisampleState.sampleMask;
        result->depthStencilState = depthStencilState;
        result->stencilReference = pipelineCreateInfo->depthStencilState.reference;
        result->rasterizerState = pipelineCreateInfo->rasterizerState;
        result->primitiveType = pipelineCreateInfo->primitiveType;
        result->vertexSamplerCount = vertexShader->samplerCount;
        result->vertexUniformBufferCount = vertexShader->uniformBufferCount;
        result->vertexStorageBufferCount = vertexShader->storageBufferCount;
        result->vertexStorageTextureCount = vertexShader->storageTextureCount;
        result->fragmentSamplerCount = fragmentShader->samplerCount;
        result->fragmentUniformBufferCount = fragmentShader->uniformBufferCount;
        result->fragmentStorageBufferCount = fragmentShader->storageBufferCount;
        result->fragmentStorageTextureCount = fragmentShader->storageTextureCount;
        return (SDL_GpuGraphicsPipeline *)result;
    }
}

/* Debug Naming */

static void METAL_SetBufferName(
    SDL_GpuRenderer *driverData,
    SDL_GpuBuffer *buffer,
    const char *text)
{
    @autoreleasepool {
        MetalRenderer *renderer = (MetalRenderer *)driverData;
        MetalBufferContainer *container = (MetalBufferContainer *)buffer;
        size_t textLength = SDL_strlen(text) + 1;

        if (renderer->debugMode) {
            container->debugName = SDL_realloc(
                container->debugName,
                textLength);

            SDL_utf8strlcpy(
                container->debugName,
                text,
                textLength);

            for (Uint32 i = 0; i < container->bufferCount; i += 1) {
                container->buffers[i]->handle.label = @(text);
            }
        }
    }
}

static void METAL_SetTextureName(
    SDL_GpuRenderer *driverData,
    SDL_GpuTexture *texture,
    const char *text)
{
    @autoreleasepool {
        MetalRenderer *renderer = (MetalRenderer *)driverData;
        MetalTextureContainer *container = (MetalTextureContainer *)texture;
        size_t textLength = SDL_strlen(text) + 1;

        if (renderer->debugMode) {
            container->debugName = SDL_realloc(
                container->debugName,
                textLength);

            SDL_utf8strlcpy(
                container->debugName,
                text,
                textLength);

            for (Uint32 i = 0; i < container->textureCount; i += 1) {
                container->textures[i]->handle.label = @(text);
            }
        }
    }
}

static void METAL_InsertDebugLabel(
    SDL_GpuCommandBuffer *commandBuffer,
    const char *text)
{
    @autoreleasepool {
        MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
        NSString *label = @(text);

        if (metalCommandBuffer->renderEncoder) {
            [metalCommandBuffer->renderEncoder insertDebugSignpost:label];
        } else if (metalCommandBuffer->blitEncoder) {
            [metalCommandBuffer->blitEncoder insertDebugSignpost:label];
        } else if (metalCommandBuffer->computeEncoder) {
            [metalCommandBuffer->computeEncoder insertDebugSignpost:label];
        } else {
            /* Metal doesn't have insertDebugSignpost for command buffers... */
            [metalCommandBuffer->handle pushDebugGroup:label];
            [metalCommandBuffer->handle popDebugGroup];
        }
    }
}

static void METAL_PushDebugGroup(
    SDL_GpuCommandBuffer *commandBuffer,
    const char *name)
{
    @autoreleasepool {
        MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
        NSString *label = @(name);

        if (metalCommandBuffer->renderEncoder) {
            [metalCommandBuffer->renderEncoder pushDebugGroup:label];
        } else if (metalCommandBuffer->blitEncoder) {
            [metalCommandBuffer->blitEncoder pushDebugGroup:label];
        } else if (metalCommandBuffer->computeEncoder) {
            [metalCommandBuffer->computeEncoder pushDebugGroup:label];
        } else {
            [metalCommandBuffer->handle pushDebugGroup:label];
        }
    }
}

static void METAL_PopDebugGroup(
    SDL_GpuCommandBuffer *commandBuffer)
{
    @autoreleasepool {
        MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;

        if (metalCommandBuffer->renderEncoder) {
            [metalCommandBuffer->renderEncoder popDebugGroup];
        } else if (metalCommandBuffer->blitEncoder) {
            [metalCommandBuffer->blitEncoder popDebugGroup];
        } else if (metalCommandBuffer->computeEncoder) {
            [metalCommandBuffer->computeEncoder popDebugGroup];
        } else {
            [metalCommandBuffer->handle popDebugGroup];
        }
    }
}

/* Resource Creation */

static SDL_GpuSampler *METAL_CreateSampler(
    SDL_GpuRenderer *driverData,
    SDL_GpuSamplerCreateInfo *samplerCreateInfo)
{
    @autoreleasepool {
        MetalRenderer *renderer = (MetalRenderer *)driverData;
        MTLSamplerDescriptor *samplerDesc = [MTLSamplerDescriptor new];
        id<MTLSamplerState> sampler;
        MetalSampler *metalSampler;

        samplerDesc.rAddressMode = SDLToMetal_SamplerAddressMode[samplerCreateInfo->addressModeU];
        samplerDesc.sAddressMode = SDLToMetal_SamplerAddressMode[samplerCreateInfo->addressModeV];
        samplerDesc.tAddressMode = SDLToMetal_SamplerAddressMode[samplerCreateInfo->addressModeW];
        samplerDesc.minFilter = SDLToMetal_MinMagFilter[samplerCreateInfo->minFilter];
        samplerDesc.magFilter = SDLToMetal_MinMagFilter[samplerCreateInfo->magFilter];
        samplerDesc.mipFilter = SDLToMetal_MipFilter[samplerCreateInfo->mipmapMode]; /* FIXME: Is this right with non-mipmapped samplers? */
        samplerDesc.lodMinClamp = samplerCreateInfo->minLod;
        samplerDesc.lodMaxClamp = samplerCreateInfo->maxLod;
        samplerDesc.maxAnisotropy = (NSUInteger)((samplerCreateInfo->anisotropyEnable) ? samplerCreateInfo->maxAnisotropy : 1);
        samplerDesc.compareFunction = (samplerCreateInfo->compareEnable) ? SDLToMetal_CompareOp[samplerCreateInfo->compareOp] : MTLCompareFunctionAlways;
        samplerDesc.borderColor = MTLSamplerBorderColorTransparentBlack; /* arbitrary, unused */

        sampler = [renderer->device newSamplerStateWithDescriptor:samplerDesc];
        if (sampler == NULL) {
            SDL_LogError(SDL_LOG_CATEGORY_GPU, "Failed to create sampler");
            return NULL;
        }

        metalSampler = (MetalSampler *)SDL_malloc(sizeof(MetalSampler));
        metalSampler->handle = sampler;
        return (SDL_GpuSampler *)metalSampler;
    }
}

static SDL_GpuShader *METAL_CreateShader(
    SDL_GpuRenderer *driverData,
    SDL_GpuShaderCreateInfo *shaderCreateInfo)
{
    @autoreleasepool {
        MetalLibraryFunction libraryFunction;
        MetalShader *result;

        libraryFunction = METAL_INTERNAL_CompileShader(
            (MetalRenderer *)driverData,
            shaderCreateInfo->format,
            shaderCreateInfo->code,
            shaderCreateInfo->codeSize,
            shaderCreateInfo->entryPointName);

        if (libraryFunction.library == nil || libraryFunction.function == nil) {
            return NULL;
        }

        result = SDL_malloc(sizeof(MetalShader));
        result->library = libraryFunction.library;
        result->function = libraryFunction.function;
        result->samplerCount = shaderCreateInfo->samplerCount;
        result->storageBufferCount = shaderCreateInfo->storageBufferCount;
        result->storageTextureCount = shaderCreateInfo->storageTextureCount;
        result->uniformBufferCount = shaderCreateInfo->uniformBufferCount;
        return (SDL_GpuShader *)result;
    }
}

/* This function assumes that it's called from within an autorelease pool */
static MetalTexture *METAL_INTERNAL_CreateTexture(
    MetalRenderer *renderer,
    SDL_GpuTextureCreateInfo *textureCreateInfo)
{
    MTLTextureDescriptor *textureDescriptor = [MTLTextureDescriptor new];
    id<MTLTexture> texture;
    id<MTLTexture> msaaTexture = NULL;
    MetalTexture *metalTexture;

    textureDescriptor.textureType = SDLToMetal_TextureType[textureCreateInfo->type];
    textureDescriptor.pixelFormat = SDLToMetal_SurfaceFormat[textureCreateInfo->format];
    /* This format isn't natively supported so let's swizzle! */
    if (textureCreateInfo->format == SDL_GPU_TEXTUREFORMAT_B4G4R4A4) {
        textureDescriptor.swizzle = MTLTextureSwizzleChannelsMake(
            MTLTextureSwizzleBlue,
            MTLTextureSwizzleGreen,
            MTLTextureSwizzleRed,
            MTLTextureSwizzleAlpha);
    }

    textureDescriptor.width = textureCreateInfo->width;
    textureDescriptor.height = textureCreateInfo->height;
    textureDescriptor.depth = textureCreateInfo->depth;
    textureDescriptor.mipmapLevelCount = textureCreateInfo->levelCount;
    textureDescriptor.sampleCount = 1;
    textureDescriptor.arrayLength = (textureCreateInfo->type == SDL_GPU_TEXTURETYPE_2D_ARRAY) ? textureCreateInfo->layerCount : 1;
    textureDescriptor.storageMode = MTLStorageModePrivate;

    textureDescriptor.usage = 0;
    if (textureCreateInfo->usageFlags & (SDL_GPU_TEXTUREUSAGE_COLOR_TARGET_BIT |
                                         SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET_BIT)) {
        textureDescriptor.usage |= MTLTextureUsageRenderTarget;
    }
    if (textureCreateInfo->usageFlags & (SDL_GPU_TEXTUREUSAGE_SAMPLER_BIT |
                                         SDL_GPU_TEXTUREUSAGE_GRAPHICS_STORAGE_READ_BIT |
                                         SDL_GPU_TEXTUREUSAGE_COMPUTE_STORAGE_READ_BIT)) {
        textureDescriptor.usage |= MTLTextureUsageShaderRead;
    }
    if (textureCreateInfo->usageFlags & SDL_GPU_TEXTUREUSAGE_COMPUTE_STORAGE_WRITE_BIT) {
        textureDescriptor.usage |= MTLTextureUsageShaderWrite;
    }

    texture = [renderer->device newTextureWithDescriptor:textureDescriptor];
    if (texture == NULL) {
        SDL_LogError(SDL_LOG_CATEGORY_GPU, "Failed to create MTLTexture!");
        return NULL;
    }

    /* Create the MSAA texture, if needed */
    if (textureCreateInfo->sampleCount > SDL_GPU_SAMPLECOUNT_1 && textureCreateInfo->type == SDL_GPU_TEXTURETYPE_2D) {
        textureDescriptor.textureType = MTLTextureType2DMultisample;
        textureDescriptor.sampleCount = SDLToMetal_SampleCount[textureCreateInfo->sampleCount];
        textureDescriptor.usage = MTLTextureUsageRenderTarget;

        msaaTexture = [renderer->device newTextureWithDescriptor:textureDescriptor];
        if (msaaTexture == NULL) {
            SDL_LogError(SDL_LOG_CATEGORY_GPU, "Failed to create MSAA MTLTexture!");
            return NULL;
        }
    }

    metalTexture = (MetalTexture *)SDL_malloc(sizeof(MetalTexture));
    metalTexture->handle = texture;
    metalTexture->msaaHandle = msaaTexture;
    SDL_AtomicSet(&metalTexture->referenceCount, 0);
    return metalTexture;
}

static SDL_GpuSampleCount METAL_GetBestSampleCount(
    SDL_GpuRenderer *driverData,
    SDL_GpuTextureFormat format,
    SDL_GpuSampleCount desiredSampleCount)
{
    @autoreleasepool {
        MetalRenderer *renderer = (MetalRenderer *)driverData;
        SDL_GpuSampleCount highestSupported = desiredSampleCount;

        if ((format == SDL_GPU_TEXTUREFORMAT_R32_SFLOAT ||
             format == SDL_GPU_TEXTUREFORMAT_R32G32_SFLOAT ||
             format == SDL_GPU_TEXTUREFORMAT_R32G32B32A32_SFLOAT)) {
            if (@available(macOS 11.0, *)) {
                if (![renderer->device supports32BitMSAA]) {
                    return SDL_GPU_SAMPLECOUNT_1;
                }
            } else {
                return SDL_GPU_SAMPLECOUNT_1;
            }
        }

        while (highestSupported > SDL_GPU_SAMPLECOUNT_1) {
            if ([renderer->device supportsTextureSampleCount:(1 << highestSupported)]) {
                break;
            }
            highestSupported -= 1;
        }

        return highestSupported;
    }
}

static SDL_GpuTexture *METAL_CreateTexture(
    SDL_GpuRenderer *driverData,
    SDL_GpuTextureCreateInfo *textureCreateInfo)
{
    @autoreleasepool {
        MetalRenderer *renderer = (MetalRenderer *)driverData;
        MetalTextureContainer *container;
        MetalTexture *texture;
        SDL_GpuTextureCreateInfo newTextureCreateInfo = *textureCreateInfo;

        newTextureCreateInfo.sampleCount = METAL_GetBestSampleCount(
            driverData,
            textureCreateInfo->format,
            textureCreateInfo->sampleCount);

        texture = METAL_INTERNAL_CreateTexture(
            renderer,
            &newTextureCreateInfo);

        if (texture == NULL) {
            SDL_LogError(SDL_LOG_CATEGORY_GPU, "Failed to create texture!");
            return NULL;
        }

        container = SDL_malloc(sizeof(MetalTextureContainer));
        container->canBeCycled = 1;
        container->header.info = *textureCreateInfo;
        container->activeTexture = texture;
        container->textureCapacity = 1;
        container->textureCount = 1;
        container->textures = SDL_malloc(
            container->textureCapacity * sizeof(MetalTexture *));
        container->textures[0] = texture;
        container->debugName = NULL;

        return (SDL_GpuTexture *)container;
    }
}

/* This function assumes that it's called from within an autorelease pool */
static MetalTexture *METAL_INTERNAL_PrepareTextureForWrite(
    MetalRenderer *renderer,
    MetalTextureContainer *container,
    SDL_bool cycle)
{
    Uint32 i;

    /* Cycle the active texture handle if needed */
    if (cycle && container->canBeCycled) {
        for (i = 0; i < container->textureCount; i += 1) {
            if (SDL_AtomicGet(&container->textures[i]->referenceCount) == 0) {
                container->activeTexture = container->textures[i];
                return container->activeTexture;
            }
        }

        EXPAND_ARRAY_IF_NEEDED(
            container->textures,
            MetalTexture *,
            container->textureCount + 1,
            container->textureCapacity,
            container->textureCapacity + 1);

        container->textures[container->textureCount] = METAL_INTERNAL_CreateTexture(
            renderer,
            &container->header.info);
        container->textureCount += 1;

        container->activeTexture = container->textures[container->textureCount - 1];

        if (renderer->debugMode && container->debugName != NULL) {
            container->activeTexture->handle.label = @(container->debugName);
        }
    }

    return container->activeTexture;
}

/* This function assumes that it's called from within an autorelease pool */
static MetalBuffer *METAL_INTERNAL_CreateBuffer(
    MetalRenderer *renderer,
    Uint32 sizeInBytes,
    MTLResourceOptions resourceOptions)
{
    id<MTLBuffer> bufferHandle;
    MetalBuffer *metalBuffer;

    /* Storage buffers have to be 4-aligned, so might as well align them all */
    sizeInBytes = METAL_INTERNAL_NextHighestAlignment(sizeInBytes, 4);

    bufferHandle = [renderer->device newBufferWithLength:sizeInBytes options:resourceOptions];
    if (bufferHandle == NULL) {
        SDL_LogError(SDL_LOG_CATEGORY_GPU, "Could not create buffer");
        return NULL;
    }

    metalBuffer = SDL_malloc(sizeof(MetalBuffer));
    metalBuffer->handle = bufferHandle;
    SDL_AtomicSet(&metalBuffer->referenceCount, 0);

    return metalBuffer;
}

/* This function assumes that it's called from within an autorelease pool */
static MetalBufferContainer *METAL_INTERNAL_CreateBufferContainer(
    MetalRenderer *renderer,
    Uint32 sizeInBytes,
    SDL_bool isPrivate,
    SDL_bool isWriteOnly)
{
    MetalBufferContainer *container = SDL_malloc(sizeof(MetalBufferContainer));
    MTLResourceOptions resourceOptions;

    container->size = sizeInBytes;
    container->bufferCapacity = 1;
    container->bufferCount = 1;
    container->buffers = SDL_malloc(
        container->bufferCapacity * sizeof(MetalBuffer *));
    container->isPrivate = isPrivate;
    container->isWriteOnly = isWriteOnly;
    container->debugName = NULL;

    if (isPrivate) {
        resourceOptions = MTLResourceStorageModePrivate;
    } else {
        if (isWriteOnly) {
            resourceOptions = MTLResourceCPUCacheModeWriteCombined;
        } else {
            resourceOptions = MTLResourceCPUCacheModeDefaultCache;
        }
    }

    container->buffers[0] = METAL_INTERNAL_CreateBuffer(
        renderer,
        sizeInBytes,
        resourceOptions);
    container->activeBuffer = container->buffers[0];

    return container;
}

static SDL_GpuBuffer *METAL_CreateBuffer(
    SDL_GpuRenderer *driverData,
    SDL_GpuBufferUsageFlags usageFlags,
    Uint32 sizeInBytes)
{
    @autoreleasepool {
        return (SDL_GpuBuffer *)METAL_INTERNAL_CreateBufferContainer(
            (MetalRenderer *)driverData,
            sizeInBytes,
            SDL_TRUE,
            SDL_FALSE);
    }
}

static SDL_GpuTransferBuffer *METAL_CreateTransferBuffer(
    SDL_GpuRenderer *driverData,
    SDL_GpuTransferBufferUsage usage,
    Uint32 sizeInBytes)
{
    @autoreleasepool {
        return (SDL_GpuTransferBuffer *)METAL_INTERNAL_CreateBufferContainer(
            (MetalRenderer *)driverData,
            sizeInBytes,
            SDL_FALSE,
            usage == SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD);
    }
}

/* This function assumes that it's called from within an autorelease pool */
static MetalUniformBuffer *METAL_INTERNAL_CreateUniformBuffer(
    MetalRenderer *renderer,
    Uint32 sizeInBytes)
{
    MetalUniformBuffer *uniformBuffer;
    id<MTLBuffer> bufferHandle;

    bufferHandle = [renderer->device newBufferWithLength:sizeInBytes options:MTLResourceCPUCacheModeWriteCombined];
    if (bufferHandle == nil) {
        SDL_LogError(SDL_LOG_CATEGORY_GPU, "Could not create uniform buffer");
        return NULL;
    }

    uniformBuffer = SDL_malloc(sizeof(MetalUniformBuffer));
    uniformBuffer->handle = bufferHandle;
    uniformBuffer->writeOffset = 0;
    uniformBuffer->drawOffset = 0;

    return uniformBuffer;
}

/* This function assumes that it's called from within an autorelease pool */
static MetalBuffer *METAL_INTERNAL_PrepareBufferForWrite(
    MetalRenderer *renderer,
    MetalBufferContainer *container,
    SDL_bool cycle)
{
    MTLResourceOptions resourceOptions;
    Uint32 i;

    /* Cycle if needed */
    if (cycle && SDL_AtomicGet(&container->activeBuffer->referenceCount) > 0) {
        for (i = 0; i < container->bufferCount; i += 1) {
            if (SDL_AtomicGet(&container->buffers[i]->referenceCount) == 0) {
                container->activeBuffer = container->buffers[i];
                return container->activeBuffer;
            }
        }

        EXPAND_ARRAY_IF_NEEDED(
            container->buffers,
            MetalBuffer *,
            container->bufferCount + 1,
            container->bufferCapacity,
            container->bufferCapacity + 1);

        if (container->isPrivate) {
            resourceOptions = MTLResourceStorageModePrivate;
        } else {
            if (container->isWriteOnly) {
                resourceOptions = MTLResourceCPUCacheModeWriteCombined;
            } else {
                resourceOptions = MTLResourceCPUCacheModeDefaultCache;
            }
        }

        container->buffers[container->bufferCount] = METAL_INTERNAL_CreateBuffer(
            renderer,
            container->size,
            resourceOptions);
        container->bufferCount += 1;

        container->activeBuffer = container->buffers[container->bufferCount - 1];

        if (renderer->debugMode && container->debugName != NULL) {
            container->activeBuffer->handle.label = @(container->debugName);
        }
    }

    return container->activeBuffer;
}

/* TransferBuffer Data */

static void METAL_MapTransferBuffer(
    SDL_GpuRenderer *driverData,
    SDL_GpuTransferBuffer *transferBuffer,
    SDL_bool cycle,
    void **ppData)
{
    @autoreleasepool {
        MetalRenderer *renderer = (MetalRenderer *)driverData;
        MetalBufferContainer *container = (MetalBufferContainer *)transferBuffer;
        MetalBuffer *buffer = METAL_INTERNAL_PrepareBufferForWrite(renderer, container, cycle);

        *ppData = [buffer->handle contents];
    }
}

static void METAL_UnmapTransferBuffer(
    SDL_GpuRenderer *driverData,
    SDL_GpuTransferBuffer *transferBuffer)
{
#ifdef SDL_PLATFORM_MACOS
    @autoreleasepool {
        /* FIXME: Is this necessary? */
        MetalBufferContainer *container = (MetalBufferContainer *)transferBuffer;
        MetalBuffer *buffer = container->activeBuffer;
        if (buffer->handle.storageMode == MTLStorageModeManaged) {
            [buffer->handle didModifyRange:NSMakeRange(0, container->size)];
        }
    }
#endif
}

/* Copy Pass */

static void METAL_BeginCopyPass(
    SDL_GpuCommandBuffer *commandBuffer)
{
    @autoreleasepool {
        MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
        metalCommandBuffer->blitEncoder = [metalCommandBuffer->handle blitCommandEncoder];
    }
}

static void METAL_UploadToTexture(
    SDL_GpuCommandBuffer *commandBuffer,
    SDL_GpuTextureTransferInfo *source,
    SDL_GpuTextureRegion *destination,
    SDL_bool cycle)
{
    @autoreleasepool {
        MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
        MetalRenderer *renderer = metalCommandBuffer->renderer;
        MetalBufferContainer *bufferContainer = (MetalBufferContainer *)source->transferBuffer;
        MetalTextureContainer *textureContainer = (MetalTextureContainer *)destination->texture;

        MetalTexture *metalTexture = METAL_INTERNAL_PrepareTextureForWrite(renderer, textureContainer, cycle);

        [metalCommandBuffer->blitEncoder
                 copyFromBuffer:bufferContainer->activeBuffer->handle
                   sourceOffset:source->offset
              sourceBytesPerRow:BytesPerRow(destination->w, textureContainer->header.info.format)
            sourceBytesPerImage:BytesPerImage(destination->w, destination->h, textureContainer->header.info.format)
                     sourceSize:MTLSizeMake(destination->w, destination->h, destination->d)
                      toTexture:metalTexture->handle
               destinationSlice:destination->layer
               destinationLevel:destination->mipLevel
              destinationOrigin:MTLOriginMake(destination->x, destination->y, destination->z)];

        METAL_INTERNAL_TrackTexture(metalCommandBuffer, metalTexture);
        METAL_INTERNAL_TrackBuffer(metalCommandBuffer, bufferContainer->activeBuffer);
    }
}

static void METAL_UploadToBuffer(
    SDL_GpuCommandBuffer *commandBuffer,
    SDL_GpuTransferBufferLocation *source,
    SDL_GpuBufferRegion *destination,
    SDL_bool cycle)
{
    @autoreleasepool {
        MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
        MetalRenderer *renderer = metalCommandBuffer->renderer;
        MetalBufferContainer *transferContainer = (MetalBufferContainer *)source->transferBuffer;
        MetalBufferContainer *bufferContainer = (MetalBufferContainer *)destination->buffer;

        MetalBuffer *metalBuffer = METAL_INTERNAL_PrepareBufferForWrite(
            renderer,
            bufferContainer,
            cycle);

        [metalCommandBuffer->blitEncoder
               copyFromBuffer:transferContainer->activeBuffer->handle
                 sourceOffset:source->offset
                     toBuffer:metalBuffer->handle
            destinationOffset:destination->offset
                         size:destination->size];

        METAL_INTERNAL_TrackBuffer(metalCommandBuffer, metalBuffer);
        METAL_INTERNAL_TrackBuffer(metalCommandBuffer, transferContainer->activeBuffer);
    }
}

static void METAL_CopyTextureToTexture(
    SDL_GpuCommandBuffer *commandBuffer,
    SDL_GpuTextureLocation *source,
    SDL_GpuTextureLocation *destination,
    Uint32 w,
    Uint32 h,
    Uint32 d,
    SDL_bool cycle)
{
    @autoreleasepool {
        MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
        MetalRenderer *renderer = metalCommandBuffer->renderer;
        MetalTextureContainer *srcContainer = (MetalTextureContainer *)source->texture;
        MetalTextureContainer *dstContainer = (MetalTextureContainer *)destination->texture;

        MetalTexture *srcTexture = srcContainer->activeTexture;
        MetalTexture *dstTexture = METAL_INTERNAL_PrepareTextureForWrite(
            renderer,
            dstContainer,
            cycle);

        [metalCommandBuffer->blitEncoder
              copyFromTexture:srcTexture->handle
                  sourceSlice:source->layer
                  sourceLevel:source->mipLevel
                 sourceOrigin:MTLOriginMake(source->x, source->y, source->z)
                   sourceSize:MTLSizeMake(w, h, d)
                    toTexture:dstTexture->handle
             destinationSlice:destination->layer
             destinationLevel:destination->mipLevel
            destinationOrigin:MTLOriginMake(destination->x, destination->y, destination->z)];

        METAL_INTERNAL_TrackTexture(metalCommandBuffer, srcTexture);
        METAL_INTERNAL_TrackTexture(metalCommandBuffer, dstTexture);
    }
}

static void METAL_CopyBufferToBuffer(
    SDL_GpuCommandBuffer *commandBuffer,
    SDL_GpuBufferLocation *source,
    SDL_GpuBufferLocation *destination,
    Uint32 size,
    SDL_bool cycle)
{
    @autoreleasepool {
        MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
        MetalRenderer *renderer = metalCommandBuffer->renderer;
        MetalBufferContainer *srcContainer = (MetalBufferContainer *)source->buffer;
        MetalBufferContainer *dstContainer = (MetalBufferContainer *)destination->buffer;

        MetalBuffer *srcBuffer = srcContainer->activeBuffer;
        MetalBuffer *dstBuffer = METAL_INTERNAL_PrepareBufferForWrite(
            renderer,
            dstContainer,
            cycle);

        [metalCommandBuffer->blitEncoder
               copyFromBuffer:srcBuffer->handle
                 sourceOffset:source->offset
                     toBuffer:dstBuffer->handle
            destinationOffset:destination->offset
                         size:size];

        METAL_INTERNAL_TrackBuffer(metalCommandBuffer, srcBuffer);
        METAL_INTERNAL_TrackBuffer(metalCommandBuffer, dstBuffer);
    }
}

static void METAL_GenerateMipmaps(
    SDL_GpuCommandBuffer *commandBuffer,
    SDL_GpuTexture *texture)
{
    @autoreleasepool {
        MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
        MetalTextureContainer *container = (MetalTextureContainer *)texture;
        MetalTexture *metalTexture = container->activeTexture;

        if (container->header.info.levelCount <= 1) {
            SDL_LogError(SDL_LOG_CATEGORY_GPU, "Cannot generate mipmaps for texture with levelCount <= 1!");
            return;
        }

        [metalCommandBuffer->blitEncoder
            generateMipmapsForTexture:metalTexture->handle];

        METAL_INTERNAL_TrackTexture(metalCommandBuffer, metalTexture);
    }
}

static void METAL_DownloadFromTexture(
    SDL_GpuCommandBuffer *commandBuffer,
    SDL_GpuTextureRegion *source,
    SDL_GpuTextureTransferInfo *destination)
{
    @autoreleasepool {
        MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
        MetalRenderer *renderer = metalCommandBuffer->renderer;
        MetalTextureContainer *textureContainer = (MetalTextureContainer *)source->texture;
        MetalTexture *metalTexture = textureContainer->activeTexture;
        MetalBufferContainer *bufferContainer = (MetalBufferContainer *)destination->transferBuffer;
        Uint32 bufferStride = destination->imagePitch;
        Uint32 bufferImageHeight = destination->imageHeight;
        Uint32 bytesPerRow, bytesPerDepthSlice;

        MetalBuffer *dstBuffer = METAL_INTERNAL_PrepareBufferForWrite(
            renderer,
            bufferContainer,
            SDL_FALSE);

        MTLOrigin regionOrigin = MTLOriginMake(
            source->x,
            source->y,
            source->z);

        MTLSize regionSize = MTLSizeMake(
            source->w,
            source->h,
            source->d);

        if (bufferStride == 0 || bufferImageHeight == 0) {
            bufferStride = source->w;
            bufferImageHeight = source->h;
        }

        bytesPerRow = BytesPerRow(bufferStride, textureContainer->header.info.format);
        bytesPerDepthSlice = bytesPerRow * bufferImageHeight;

        [metalCommandBuffer->blitEncoder
                     copyFromTexture:metalTexture->handle
                         sourceSlice:source->layer
                         sourceLevel:source->mipLevel
                        sourceOrigin:regionOrigin
                          sourceSize:regionSize
                            toBuffer:dstBuffer->handle
                   destinationOffset:destination->offset
              destinationBytesPerRow:bytesPerRow
            destinationBytesPerImage:bytesPerDepthSlice];

        METAL_INTERNAL_TrackTexture(metalCommandBuffer, metalTexture);
        METAL_INTERNAL_TrackBuffer(metalCommandBuffer, dstBuffer);
    }
}

static void METAL_DownloadFromBuffer(
    SDL_GpuCommandBuffer *commandBuffer,
    SDL_GpuBufferRegion *source,
    SDL_GpuTransferBufferLocation *destination)
{
    SDL_GpuBufferLocation sourceLocation;
    sourceLocation.buffer = source->buffer;
    sourceLocation.offset = source->offset;

    METAL_CopyBufferToBuffer(
        commandBuffer,
        &sourceLocation,
        (SDL_GpuBufferLocation *)destination,
        source->size,
        SDL_FALSE);
}

static void METAL_EndCopyPass(
    SDL_GpuCommandBuffer *commandBuffer)
{
    @autoreleasepool {
        MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
        [metalCommandBuffer->blitEncoder endEncoding];
        metalCommandBuffer->blitEncoder = nil;
    }
}

/* Graphics State */

static void METAL_INTERNAL_AllocateCommandBuffers(
    MetalRenderer *renderer,
    Uint32 allocateCount)
{
    MetalCommandBuffer *commandBuffer;

    renderer->availableCommandBufferCapacity += allocateCount;

    renderer->availableCommandBuffers = SDL_realloc(
        renderer->availableCommandBuffers,
        sizeof(MetalCommandBuffer *) * renderer->availableCommandBufferCapacity);

    for (Uint32 i = 0; i < allocateCount; i += 1) {
        commandBuffer = SDL_calloc(1, sizeof(MetalCommandBuffer));
        commandBuffer->renderer = renderer;

        /* The native Metal command buffer is created in METAL_AcquireCommandBuffer */

        commandBuffer->windowDataCapacity = 1;
        commandBuffer->windowDataCount = 0;
        commandBuffer->windowDatas = SDL_malloc(
            commandBuffer->windowDataCapacity * sizeof(MetalWindowData *));

        /* Reference Counting */
        commandBuffer->usedBufferCapacity = 4;
        commandBuffer->usedBufferCount = 0;
        commandBuffer->usedBuffers = SDL_malloc(
            commandBuffer->usedBufferCapacity * sizeof(MetalBuffer *));

        commandBuffer->usedTextureCapacity = 4;
        commandBuffer->usedTextureCount = 0;
        commandBuffer->usedTextures = SDL_malloc(
            commandBuffer->usedTextureCapacity * sizeof(MetalTexture *));

        renderer->availableCommandBuffers[renderer->availableCommandBufferCount] = commandBuffer;
        renderer->availableCommandBufferCount += 1;
    }
}

static MetalCommandBuffer *METAL_INTERNAL_GetInactiveCommandBufferFromPool(
    MetalRenderer *renderer)
{
    MetalCommandBuffer *commandBuffer;

    if (renderer->availableCommandBufferCount == 0) {
        METAL_INTERNAL_AllocateCommandBuffers(
            renderer,
            renderer->availableCommandBufferCapacity);
    }

    commandBuffer = renderer->availableCommandBuffers[renderer->availableCommandBufferCount - 1];
    renderer->availableCommandBufferCount -= 1;

    return commandBuffer;
}

static Uint8 METAL_INTERNAL_CreateFence(
    MetalRenderer *renderer)
{
    MetalFence *fence;

    fence = SDL_malloc(sizeof(MetalFence));
    SDL_AtomicSet(&fence->complete, 0);

    /* Add it to the available pool */
    /* FIXME: Should this be EXPAND_IF_NEEDED? */
    if (renderer->availableFenceCount >= renderer->availableFenceCapacity) {
        renderer->availableFenceCapacity *= 2;

        renderer->availableFences = SDL_realloc(
            renderer->availableFences,
            sizeof(MetalFence *) * renderer->availableFenceCapacity);
    }

    renderer->availableFences[renderer->availableFenceCount] = fence;
    renderer->availableFenceCount += 1;

    return 1;
}

static Uint8 METAL_INTERNAL_AcquireFence(
    MetalRenderer *renderer,
    MetalCommandBuffer *commandBuffer)
{
    MetalFence *fence;

    /* Acquire a fence from the pool */
    SDL_LockMutex(renderer->fenceLock);

    if (renderer->availableFenceCount == 0) {
        if (!METAL_INTERNAL_CreateFence(renderer)) {
            SDL_UnlockMutex(renderer->fenceLock);
            SDL_LogError(SDL_LOG_CATEGORY_GPU, "Failed to create fence!");
            return 0;
        }
    }

    fence = renderer->availableFences[renderer->availableFenceCount - 1];
    renderer->availableFenceCount -= 1;

    SDL_UnlockMutex(renderer->fenceLock);

    /* Associate the fence with the command buffer */
    commandBuffer->fence = fence;
    SDL_AtomicSet(&fence->complete, 0); /* FIXME: Is this right? */

    return 1;
}

static SDL_GpuCommandBuffer *METAL_AcquireCommandBuffer(
    SDL_GpuRenderer *driverData)
{
    @autoreleasepool {
        MetalRenderer *renderer = (MetalRenderer *)driverData;
        MetalCommandBuffer *commandBuffer;

        SDL_LockMutex(renderer->acquireCommandBufferLock);

        commandBuffer = METAL_INTERNAL_GetInactiveCommandBufferFromPool(renderer);
        commandBuffer->handle = [renderer->queue commandBuffer];

        commandBuffer->graphicsPipeline = NULL;
        commandBuffer->computePipeline = NULL;
        for (Uint32 i = 0; i < MAX_UNIFORM_BUFFERS_PER_STAGE; i += 1) {
            commandBuffer->vertexUniformBuffers[i] = NULL;
            commandBuffer->fragmentUniformBuffers[i] = NULL;
            commandBuffer->computeUniformBuffers[i] = NULL;
        }

        /* FIXME: Do we actually need to set this? */
        commandBuffer->needVertexSamplerBind = SDL_TRUE;
        commandBuffer->needVertexStorageTextureBind = SDL_TRUE;
        commandBuffer->needVertexStorageBufferBind = SDL_TRUE;
        commandBuffer->needVertexUniformBind = SDL_TRUE;
        commandBuffer->needFragmentSamplerBind = SDL_TRUE;
        commandBuffer->needFragmentStorageTextureBind = SDL_TRUE;
        commandBuffer->needFragmentStorageBufferBind = SDL_TRUE;
        commandBuffer->needFragmentUniformBind = SDL_TRUE;
        commandBuffer->needComputeBufferBind = SDL_TRUE;
        commandBuffer->needComputeTextureBind = SDL_TRUE;
        commandBuffer->needComputeUniformBind = SDL_TRUE;

        METAL_INTERNAL_AcquireFence(renderer, commandBuffer);
        commandBuffer->autoReleaseFence = 1;

        SDL_UnlockMutex(renderer->acquireCommandBufferLock);

        return (SDL_GpuCommandBuffer *)commandBuffer;
    }
}

/* This function assumes that it's called from within an autorelease pool */
static MetalUniformBuffer *METAL_INTERNAL_AcquireUniformBufferFromPool(
    MetalCommandBuffer *commandBuffer)
{
    MetalRenderer *renderer = commandBuffer->renderer;
    MetalUniformBuffer *uniformBuffer;

    SDL_LockMutex(renderer->acquireUniformBufferLock);

    if (renderer->uniformBufferPoolCount > 0) {
        uniformBuffer = renderer->uniformBufferPool[renderer->uniformBufferPoolCount - 1];
        renderer->uniformBufferPoolCount -= 1;
    } else {
        uniformBuffer = METAL_INTERNAL_CreateUniformBuffer(
            renderer,
            UNIFORM_BUFFER_SIZE);
    }

    SDL_UnlockMutex(renderer->acquireUniformBufferLock);

    METAL_INTERNAL_TrackUniformBuffer(commandBuffer, uniformBuffer);

    return uniformBuffer;
}

static void METAL_INTERNAL_ReturnUniformBufferToPool(
    MetalRenderer *renderer,
    MetalUniformBuffer *uniformBuffer)
{
    if (renderer->uniformBufferPoolCount >= renderer->uniformBufferPoolCapacity) {
        renderer->uniformBufferPoolCapacity *= 2;
        renderer->uniformBufferPool = SDL_realloc(
            renderer->uniformBufferPool,
            renderer->uniformBufferPoolCapacity * sizeof(MetalUniformBuffer *));
    }

    renderer->uniformBufferPool[renderer->uniformBufferPoolCount] = uniformBuffer;
    renderer->uniformBufferPoolCount += 1;

    uniformBuffer->writeOffset = 0;
    uniformBuffer->drawOffset = 0;
}

static void METAL_BeginRenderPass(
    SDL_GpuCommandBuffer *commandBuffer,
    SDL_GpuColorAttachmentInfo *colorAttachmentInfos,
    Uint32 colorAttachmentCount,
    SDL_GpuDepthStencilAttachmentInfo *depthStencilAttachmentInfo)
{
    @autoreleasepool {
        MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
        MetalRenderer *renderer = metalCommandBuffer->renderer;
        MTLRenderPassDescriptor *passDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];
        Uint32 vpWidth = UINT_MAX;
        Uint32 vpHeight = UINT_MAX;
        MTLViewport viewport;
        MTLScissorRect scissorRect;

        for (Uint32 i = 0; i < colorAttachmentCount; i += 1) {
            MetalTextureContainer *container = (MetalTextureContainer *)colorAttachmentInfos[i].texture;
            MetalTexture *texture = METAL_INTERNAL_PrepareTextureForWrite(
                renderer,
                container,
                colorAttachmentInfos[i].cycle);

            if (texture->msaaHandle) {
                passDescriptor.colorAttachments[i].texture = texture->msaaHandle;
                passDescriptor.colorAttachments[i].resolveTexture = texture->handle;
            } else {
                passDescriptor.colorAttachments[i].texture = texture->handle;
            }
            passDescriptor.colorAttachments[i].level = colorAttachmentInfos[i].mipLevel;
            if (container->header.info.type == SDL_GPU_TEXTURETYPE_3D) {
                passDescriptor.colorAttachments[i].depthPlane = colorAttachmentInfos[i].layerOrDepthPlane;
            } else {
                passDescriptor.colorAttachments[i].slice = colorAttachmentInfos[i].layerOrDepthPlane;
            }
            passDescriptor.colorAttachments[i].clearColor = MTLClearColorMake(
                colorAttachmentInfos[i].clearColor.r,
                colorAttachmentInfos[i].clearColor.g,
                colorAttachmentInfos[i].clearColor.b,
                colorAttachmentInfos[i].clearColor.a);
            passDescriptor.colorAttachments[i].loadAction = SDLToMetal_LoadOp[colorAttachmentInfos[i].loadOp];
            passDescriptor.colorAttachments[i].storeAction = SDLToMetal_StoreOp(
                colorAttachmentInfos[i].storeOp,
                texture->msaaHandle ? 1 : 0);

            METAL_INTERNAL_TrackTexture(metalCommandBuffer, texture);
        }

        if (depthStencilAttachmentInfo != NULL) {
            MetalTextureContainer *container = (MetalTextureContainer *)depthStencilAttachmentInfo->texture;
            MetalTexture *texture = METAL_INTERNAL_PrepareTextureForWrite(
                renderer,
                container,
                depthStencilAttachmentInfo->cycle);

            if (texture->msaaHandle) {
                passDescriptor.depthAttachment.texture = texture->msaaHandle;
                passDescriptor.depthAttachment.resolveTexture = texture->handle;
            } else {
                passDescriptor.depthAttachment.texture = texture->handle;
            }
            passDescriptor.depthAttachment.loadAction = SDLToMetal_LoadOp[depthStencilAttachmentInfo->loadOp];
            passDescriptor.depthAttachment.storeAction = SDLToMetal_StoreOp(
                depthStencilAttachmentInfo->storeOp,
                texture->msaaHandle ? 1 : 0);
            passDescriptor.depthAttachment.clearDepth = depthStencilAttachmentInfo->depthStencilClearValue.depth;

            if (IsStencilFormat(container->header.info.format)) {
                if (texture->msaaHandle) {
                    passDescriptor.stencilAttachment.texture = texture->msaaHandle;
                    passDescriptor.stencilAttachment.resolveTexture = texture->handle;
                } else {
                    passDescriptor.stencilAttachment.texture = texture->handle;
                }
                passDescriptor.stencilAttachment.loadAction = SDLToMetal_LoadOp[depthStencilAttachmentInfo->loadOp];
                passDescriptor.stencilAttachment.storeAction = SDLToMetal_StoreOp(
                    depthStencilAttachmentInfo->storeOp,
                    texture->msaaHandle ? 1 : 0);
                passDescriptor.stencilAttachment.clearStencil = depthStencilAttachmentInfo->depthStencilClearValue.stencil;
            }

            METAL_INTERNAL_TrackTexture(metalCommandBuffer, texture);
        }

        metalCommandBuffer->renderEncoder = [metalCommandBuffer->handle renderCommandEncoderWithDescriptor:passDescriptor];

        /* The viewport cannot be larger than the smallest attachment. */
        for (Uint32 i = 0; i < colorAttachmentCount; i += 1) {
            MetalTextureContainer *container = (MetalTextureContainer *)colorAttachmentInfos[i].texture;
            Uint32 w = container->header.info.width >> colorAttachmentInfos[i].mipLevel;
            Uint32 h = container->header.info.height >> colorAttachmentInfos[i].mipLevel;

            if (w < vpWidth) {
                vpWidth = w;
            }

            if (h < vpHeight) {
                vpHeight = h;
            }
        }

        if (depthStencilAttachmentInfo != NULL) {
            MetalTextureContainer *container = (MetalTextureContainer *)depthStencilAttachmentInfo->texture;
            Uint32 w = container->header.info.width;
            Uint32 h = container->header.info.height;

            if (w < vpWidth) {
                vpWidth = w;
            }

            if (h < vpHeight) {
                vpHeight = h;
            }
        }

        /* Set default viewport and scissor state */
        viewport.originX = 0;
        viewport.originY = 0;
        viewport.width = vpWidth;
        viewport.height = vpHeight;
        viewport.znear = 0;
        viewport.zfar = 1;
        [metalCommandBuffer->renderEncoder setViewport:viewport];

        scissorRect.x = 0;
        scissorRect.y = 0;
        scissorRect.width = vpWidth;
        scissorRect.height = vpHeight;
        [metalCommandBuffer->renderEncoder setScissorRect:scissorRect];
    }
}

static void METAL_BindGraphicsPipeline(
    SDL_GpuCommandBuffer *commandBuffer,
    SDL_GpuGraphicsPipeline *graphicsPipeline)
{
    @autoreleasepool {
        MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
        MetalGraphicsPipeline *metalGraphicsPipeline = (MetalGraphicsPipeline *)graphicsPipeline;
        SDL_GpuRasterizerState *rast = &metalGraphicsPipeline->rasterizerState;

        metalCommandBuffer->graphicsPipeline = metalGraphicsPipeline;

        [metalCommandBuffer->renderEncoder setRenderPipelineState:metalGraphicsPipeline->handle];

        /* Apply rasterizer state */
        [metalCommandBuffer->renderEncoder setTriangleFillMode:SDLToMetal_PolygonMode[metalGraphicsPipeline->rasterizerState.fillMode]];
        [metalCommandBuffer->renderEncoder setCullMode:SDLToMetal_CullMode[metalGraphicsPipeline->rasterizerState.cullMode]];
        [metalCommandBuffer->renderEncoder setFrontFacingWinding:SDLToMetal_FrontFace[metalGraphicsPipeline->rasterizerState.frontFace]];
        [metalCommandBuffer->renderEncoder
            setDepthBias:((rast->depthBiasEnable) ? rast->depthBiasConstantFactor : 0)
              slopeScale:((rast->depthBiasEnable) ? rast->depthBiasSlopeFactor : 0)
              clamp:((rast->depthBiasEnable) ? rast->depthBiasClamp : 0)];

        /* Apply blend constants */
        [metalCommandBuffer->renderEncoder
            setBlendColorRed:metalGraphicsPipeline->blendConstants[0]
                       green:metalGraphicsPipeline->blendConstants[1]
                        blue:metalGraphicsPipeline->blendConstants[2]
                       alpha:metalGraphicsPipeline->blendConstants[3]];

        /* Apply depth-stencil state */
        if (metalGraphicsPipeline->depthStencilState != NULL) {
            [metalCommandBuffer->renderEncoder
                setDepthStencilState:metalGraphicsPipeline->depthStencilState];
            [metalCommandBuffer->renderEncoder
                setStencilReferenceValue:metalGraphicsPipeline->stencilReference];
        }

        for (Uint32 i = 0; i < metalGraphicsPipeline->vertexUniformBufferCount; i += 1) {
            if (metalCommandBuffer->vertexUniformBuffers[i] == NULL) {
                metalCommandBuffer->vertexUniformBuffers[i] = METAL_INTERNAL_AcquireUniformBufferFromPool(
                    metalCommandBuffer);
            }
        }

        for (Uint32 i = 0; i < metalGraphicsPipeline->fragmentUniformBufferCount; i += 1) {
            if (metalCommandBuffer->fragmentUniformBuffers[i] == NULL) {
                metalCommandBuffer->fragmentUniformBuffers[i] = METAL_INTERNAL_AcquireUniformBufferFromPool(
                    metalCommandBuffer);
            }
        }

        metalCommandBuffer->needVertexUniformBind = SDL_TRUE;
        metalCommandBuffer->needFragmentUniformBind = SDL_TRUE;
    }
}

static void METAL_SetViewport(
    SDL_GpuCommandBuffer *commandBuffer,
    SDL_GpuViewport *viewport)
{
    @autoreleasepool {
        MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
        MTLViewport metalViewport;

        metalViewport.originX = viewport->x;
        metalViewport.originY = viewport->y;
        metalViewport.width = viewport->w;
        metalViewport.height = viewport->h;
        metalViewport.znear = viewport->minDepth;
        metalViewport.zfar = viewport->maxDepth;

        [metalCommandBuffer->renderEncoder setViewport:metalViewport];
    }
}

static void METAL_SetScissor(
    SDL_GpuCommandBuffer *commandBuffer,
    SDL_Rect *scissor)
{
    @autoreleasepool {
        MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
        MTLScissorRect metalScissor;

        metalScissor.x = scissor->x;
        metalScissor.y = scissor->y;
        metalScissor.width = scissor->w;
        metalScissor.height = scissor->h;

        [metalCommandBuffer->renderEncoder setScissorRect:metalScissor];
    }
}

static void METAL_BindVertexBuffers(
    SDL_GpuCommandBuffer *commandBuffer,
    Uint32 firstBinding,
    SDL_GpuBufferBinding *pBindings,
    Uint32 bindingCount)
{
    @autoreleasepool {
        MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
        id<MTLBuffer> metalBuffers[MAX_BUFFER_BINDINGS];
        NSUInteger bufferOffsets[MAX_BUFFER_BINDINGS];
        NSRange range = NSMakeRange(METAL_INTERNAL_GetVertexBufferIndex(firstBinding), bindingCount);

        if (range.length == 0) {
            return;
        }

        for (Uint32 i = 0; i < range.length; i += 1) {
            MetalBuffer *currentBuffer = ((MetalBufferContainer *)pBindings[i].buffer)->activeBuffer;
            NSUInteger bindingIndex = range.length - 1 - i;
            metalBuffers[bindingIndex] = currentBuffer->handle;
            bufferOffsets[bindingIndex] = pBindings[i].offset;
            METAL_INTERNAL_TrackBuffer(metalCommandBuffer, currentBuffer);
        }

        [metalCommandBuffer->renderEncoder setVertexBuffers:metalBuffers offsets:bufferOffsets withRange:range];
    }
}

static void METAL_BindIndexBuffer(
    SDL_GpuCommandBuffer *commandBuffer,
    SDL_GpuBufferBinding *pBinding,
    SDL_GpuIndexElementSize indexElementSize)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
    metalCommandBuffer->indexBuffer = ((MetalBufferContainer *)pBinding->buffer)->activeBuffer;
    metalCommandBuffer->indexBufferOffset = pBinding->offset;
    metalCommandBuffer->indexElementSize = indexElementSize;

    METAL_INTERNAL_TrackBuffer(metalCommandBuffer, metalCommandBuffer->indexBuffer);
}

static void METAL_BindVertexSamplers(
    SDL_GpuCommandBuffer *commandBuffer,
    Uint32 firstSlot,
    SDL_GpuTextureSamplerBinding *textureSamplerBindings,
    Uint32 bindingCount)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
    MetalTextureContainer *textureContainer;

    for (Uint32 i = 0; i < bindingCount; i += 1) {
        textureContainer = (MetalTextureContainer *)textureSamplerBindings[i].texture;

        METAL_INTERNAL_TrackTexture(
            metalCommandBuffer,
            textureContainer->activeTexture);

        metalCommandBuffer->vertexSamplers[firstSlot + i] =
            ((MetalSampler *)textureSamplerBindings[i].sampler)->handle;

        metalCommandBuffer->vertexTextures[firstSlot + i] =
            textureContainer->activeTexture->handle;
    }

    metalCommandBuffer->needVertexSamplerBind = SDL_TRUE;
}

static void METAL_BindVertexStorageTextures(
    SDL_GpuCommandBuffer *commandBuffer,
    Uint32 firstSlot,
    SDL_GpuTexture **storageTextures,
    Uint32 bindingCount)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
    MetalTextureContainer *textureContainer;

    for (Uint32 i = 0; i < bindingCount; i += 1) {
        textureContainer = (MetalTextureContainer *)storageTextures[i];

        METAL_INTERNAL_TrackTexture(
            metalCommandBuffer,
            textureContainer->activeTexture);

        metalCommandBuffer->vertexStorageTextures[firstSlot + i] =
            textureContainer->activeTexture->handle;
    }

    metalCommandBuffer->needVertexStorageTextureBind = SDL_TRUE;
}

static void METAL_BindVertexStorageBuffers(
    SDL_GpuCommandBuffer *commandBuffer,
    Uint32 firstSlot,
    SDL_GpuBuffer **storageBuffers,
    Uint32 bindingCount)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
    MetalBufferContainer *bufferContainer;

    for (Uint32 i = 0; i < bindingCount; i += 1) {
        bufferContainer = (MetalBufferContainer *)storageBuffers[i];

        METAL_INTERNAL_TrackBuffer(
            metalCommandBuffer,
            bufferContainer->activeBuffer);

        metalCommandBuffer->vertexStorageBuffers[firstSlot + i] =
            bufferContainer->activeBuffer->handle;
    }

    metalCommandBuffer->needVertexStorageBufferBind = SDL_TRUE;
}

static void METAL_BindFragmentSamplers(
    SDL_GpuCommandBuffer *commandBuffer,
    Uint32 firstSlot,
    SDL_GpuTextureSamplerBinding *textureSamplerBindings,
    Uint32 bindingCount)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
    MetalTextureContainer *textureContainer;

    for (Uint32 i = 0; i < bindingCount; i += 1) {
        textureContainer = (MetalTextureContainer *)textureSamplerBindings[i].texture;

        METAL_INTERNAL_TrackTexture(
            metalCommandBuffer,
            textureContainer->activeTexture);

        metalCommandBuffer->fragmentSamplers[firstSlot + i] =
            ((MetalSampler *)textureSamplerBindings[i].sampler)->handle;

        metalCommandBuffer->fragmentTextures[firstSlot + i] =
            textureContainer->activeTexture->handle;
    }

    metalCommandBuffer->needFragmentSamplerBind = SDL_TRUE;
}

static void METAL_BindFragmentStorageTextures(
    SDL_GpuCommandBuffer *commandBuffer,
    Uint32 firstSlot,
    SDL_GpuTexture **storageTextures,
    Uint32 bindingCount)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
    MetalTextureContainer *textureContainer;

    for (Uint32 i = 0; i < bindingCount; i += 1) {
        textureContainer = (MetalTextureContainer *)storageTextures[i];

        METAL_INTERNAL_TrackTexture(
            metalCommandBuffer,
            textureContainer->activeTexture);

        metalCommandBuffer->fragmentStorageTextures[firstSlot + i] =
            textureContainer->activeTexture->handle;
    }

    metalCommandBuffer->needFragmentStorageTextureBind = SDL_TRUE;
}

static void METAL_BindFragmentStorageBuffers(
    SDL_GpuCommandBuffer *commandBuffer,
    Uint32 firstSlot,
    SDL_GpuBuffer **storageBuffers,
    Uint32 bindingCount)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
    MetalBufferContainer *bufferContainer;

    for (Uint32 i = 0; i < bindingCount; i += 1) {
        bufferContainer = (MetalBufferContainer *)storageBuffers[i];

        METAL_INTERNAL_TrackBuffer(
            metalCommandBuffer,
            bufferContainer->activeBuffer);

        metalCommandBuffer->fragmentStorageBuffers[firstSlot + i] =
            bufferContainer->activeBuffer->handle;
    }

    metalCommandBuffer->needFragmentStorageBufferBind = SDL_TRUE;
}

/* This function assumes that it's called from within an autorelease pool */
static void METAL_INTERNAL_BindGraphicsResources(
    MetalCommandBuffer *commandBuffer)
{
    MetalGraphicsPipeline *graphicsPipeline = commandBuffer->graphicsPipeline;
    NSUInteger offsets[MAX_STORAGE_BUFFERS_PER_STAGE] = { 0 };

    /* Vertex Samplers+Textures */

    if (graphicsPipeline->vertexSamplerCount > 0 && commandBuffer->needVertexSamplerBind) {
        [commandBuffer->renderEncoder setVertexSamplerStates:commandBuffer->vertexSamplers
                                                   withRange:NSMakeRange(0, graphicsPipeline->vertexSamplerCount)];
        [commandBuffer->renderEncoder setVertexTextures:commandBuffer->vertexTextures
                                              withRange:NSMakeRange(0, graphicsPipeline->vertexSamplerCount)];
        commandBuffer->needVertexSamplerBind = SDL_FALSE;
    }

    /* Vertex Storage Textures */

    if (graphicsPipeline->vertexStorageTextureCount > 0 && commandBuffer->needVertexStorageTextureBind) {
        [commandBuffer->renderEncoder setVertexTextures:commandBuffer->vertexStorageTextures
                                              withRange:NSMakeRange(graphicsPipeline->vertexSamplerCount,
                                                                    graphicsPipeline->vertexStorageTextureCount)];
        commandBuffer->needVertexStorageTextureBind = SDL_FALSE;
    }

    /* Vertex Storage Buffers */

    if (graphicsPipeline->vertexStorageBufferCount > 0 && commandBuffer->needVertexStorageBufferBind) {
        [commandBuffer->renderEncoder setVertexBuffers:commandBuffer->vertexStorageBuffers
                                               offsets:offsets
                                             withRange:NSMakeRange(graphicsPipeline->vertexUniformBufferCount,
                                                                   graphicsPipeline->vertexStorageBufferCount)];
        commandBuffer->needVertexStorageBufferBind = SDL_FALSE;
    }

    /* Vertex Uniform Buffers */

    if (graphicsPipeline->vertexUniformBufferCount > 0 && commandBuffer->needVertexUniformBind) {
        for (Uint32 i = 0; i < graphicsPipeline->vertexUniformBufferCount; i += 1) {
            [commandBuffer->renderEncoder
                setVertexBuffer:commandBuffer->vertexUniformBuffers[i]->handle
                         offset:commandBuffer->vertexUniformBuffers[i]->drawOffset
                        atIndex:i];
        }
        commandBuffer->needVertexUniformBind = SDL_FALSE;
    }

    /* Fragment Samplers+Textures */

    if (graphicsPipeline->fragmentSamplerCount > 0 && commandBuffer->needFragmentSamplerBind) {
        [commandBuffer->renderEncoder setFragmentSamplerStates:commandBuffer->fragmentSamplers
                                                     withRange:NSMakeRange(0, graphicsPipeline->fragmentSamplerCount)];
        [commandBuffer->renderEncoder setFragmentTextures:commandBuffer->fragmentTextures
                                                withRange:NSMakeRange(0, graphicsPipeline->fragmentSamplerCount)];
        commandBuffer->needFragmentSamplerBind = SDL_FALSE;
    }

    /* Fragment Storage Textures */

    if (graphicsPipeline->fragmentStorageTextureCount > 0 && commandBuffer->needFragmentStorageTextureBind) {
        [commandBuffer->renderEncoder setFragmentTextures:commandBuffer->fragmentStorageTextures
                                                withRange:NSMakeRange(graphicsPipeline->fragmentSamplerCount,
                                                                      graphicsPipeline->fragmentStorageTextureCount)];
        commandBuffer->needFragmentStorageTextureBind = SDL_FALSE;
    }

    /* Fragment Storage Buffers */

    if (graphicsPipeline->fragmentStorageBufferCount > 0 && commandBuffer->needFragmentStorageBufferBind) {
        [commandBuffer->renderEncoder setFragmentBuffers:commandBuffer->fragmentStorageBuffers
                                                 offsets:offsets
                                               withRange:NSMakeRange(graphicsPipeline->fragmentUniformBufferCount,
                                                                     graphicsPipeline->fragmentStorageBufferCount)];
        commandBuffer->needFragmentStorageBufferBind = SDL_FALSE;
    }

    /* Fragment Uniform Buffers */
    if (graphicsPipeline->fragmentUniformBufferCount > 0 && commandBuffer->needFragmentUniformBind) {
        for (Uint32 i = 0; i < graphicsPipeline->fragmentUniformBufferCount; i += 1) {
            [commandBuffer->renderEncoder
                setFragmentBuffer:commandBuffer->fragmentUniformBuffers[i]->handle
                           offset:commandBuffer->fragmentUniformBuffers[i]->drawOffset
                          atIndex:i];
        }
        commandBuffer->needFragmentUniformBind = SDL_FALSE;
    }
}

/* This function assumes that it's called from within an autorelease pool */
static void METAL_INTERNAL_BindComputeResources(
    MetalCommandBuffer *commandBuffer)
{
    MetalComputePipeline *computePipeline = commandBuffer->computePipeline;
    NSUInteger offsets[MAX_STORAGE_BUFFERS_PER_STAGE] = { 0 }; /* 8 is the max for both read and read-write */

    if (commandBuffer->needComputeTextureBind) {
        /* Bind read-only textures */
        if (computePipeline->readOnlyStorageTextureCount > 0) {
            [commandBuffer->computeEncoder setTextures:commandBuffer->computeReadOnlyTextures
                                             withRange:NSMakeRange(0, computePipeline->readOnlyStorageTextureCount)];
        }

        /* Bind read-write textures */
        if (computePipeline->readWriteStorageTextureCount > 0) {
            [commandBuffer->computeEncoder setTextures:commandBuffer->computeReadWriteTextures
                                             withRange:NSMakeRange(
                                                           computePipeline->readOnlyStorageTextureCount,
                                                           computePipeline->readWriteStorageTextureCount)];
        }
        commandBuffer->needComputeTextureBind = SDL_FALSE;
    }

    if (commandBuffer->needComputeBufferBind) {
        /* Bind read-only buffers */
        if (computePipeline->readOnlyStorageBufferCount > 0) {
            [commandBuffer->computeEncoder setBuffers:commandBuffer->computeReadOnlyBuffers
                                              offsets:offsets
                                            withRange:NSMakeRange(computePipeline->uniformBufferCount,
                                                                  computePipeline->readOnlyStorageBufferCount)];
        }
        /* Bind read-write buffers */
        if (computePipeline->readWriteStorageBufferCount > 0) {
            [commandBuffer->computeEncoder setBuffers:commandBuffer->computeReadWriteBuffers
                                              offsets:offsets
                                            withRange:NSMakeRange(
                                                          computePipeline->uniformBufferCount +
                                                              computePipeline->readOnlyStorageBufferCount,
                                                          computePipeline->readWriteStorageBufferCount)];
        }
        commandBuffer->needComputeBufferBind = SDL_FALSE;
    }

    if (commandBuffer->needComputeUniformBind) {
        for (Uint32 i = 0; i < computePipeline->uniformBufferCount; i += 1) {
            [commandBuffer->computeEncoder
                setBuffer:commandBuffer->computeUniformBuffers[i]->handle
                   offset:commandBuffer->computeUniformBuffers[i]->drawOffset
                  atIndex:i];
        }

        commandBuffer->needComputeUniformBind = SDL_FALSE;
    }
}

static void METAL_DrawIndexedPrimitives(
    SDL_GpuCommandBuffer *commandBuffer,
    Uint32 baseVertex,
    Uint32 startIndex,
    Uint32 vertexCount,
    Uint32 instanceCount)
{
    @autoreleasepool {
        MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
        SDL_GpuPrimitiveType primitiveType = metalCommandBuffer->graphicsPipeline->primitiveType;
        Uint32 indexSize = IndexSize(metalCommandBuffer->indexElementSize);

        METAL_INTERNAL_BindGraphicsResources(metalCommandBuffer);

        [metalCommandBuffer->renderEncoder
            drawIndexedPrimitives:SDLToMetal_PrimitiveType[primitiveType]
                       indexCount:vertexCount
                        indexType:SDLToMetal_IndexType[metalCommandBuffer->indexElementSize]
                      indexBuffer:metalCommandBuffer->indexBuffer->handle
                indexBufferOffset:metalCommandBuffer->indexBufferOffset + (startIndex * indexSize)
                    instanceCount:instanceCount
                       baseVertex:baseVertex
                     baseInstance:0];
    }
}

static void METAL_DrawPrimitives(
    SDL_GpuCommandBuffer *commandBuffer,
    Uint32 vertexStart,
    Uint32 vertexCount)
{
    @autoreleasepool {
        MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
        SDL_GpuPrimitiveType primitiveType = metalCommandBuffer->graphicsPipeline->primitiveType;

        METAL_INTERNAL_BindGraphicsResources(metalCommandBuffer);

        [metalCommandBuffer->renderEncoder
            drawPrimitives:SDLToMetal_PrimitiveType[primitiveType]
               vertexStart:vertexStart
               vertexCount:vertexCount];
    }
}

static void METAL_DrawPrimitivesIndirect(
    SDL_GpuCommandBuffer *commandBuffer,
    SDL_GpuBuffer *buffer,
    Uint32 offsetInBytes,
    Uint32 drawCount,
    Uint32 stride)
{
    @autoreleasepool {
        MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
        MetalBuffer *metalBuffer = ((MetalBufferContainer *)buffer)->activeBuffer;
        SDL_GpuPrimitiveType primitiveType = metalCommandBuffer->graphicsPipeline->primitiveType;

        METAL_INTERNAL_BindGraphicsResources(metalCommandBuffer);

        /* Metal: "We have multi-draw at home!"
         * Multi-draw at home:
         */
        for (Uint32 i = 0; i < drawCount; i += 1) {
            [metalCommandBuffer->renderEncoder
                      drawPrimitives:SDLToMetal_PrimitiveType[primitiveType]
                      indirectBuffer:metalBuffer->handle
                indirectBufferOffset:offsetInBytes + (stride * i)];
        }

        METAL_INTERNAL_TrackBuffer(metalCommandBuffer, metalBuffer);
    }
}

static void METAL_DrawIndexedPrimitivesIndirect(
    SDL_GpuCommandBuffer *commandBuffer,
    SDL_GpuBuffer *buffer,
    Uint32 offsetInBytes,
    Uint32 drawCount,
    Uint32 stride)
{
    @autoreleasepool {
        MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
        MetalBuffer *metalBuffer = ((MetalBufferContainer *)buffer)->activeBuffer;
        SDL_GpuPrimitiveType primitiveType = metalCommandBuffer->graphicsPipeline->primitiveType;

        METAL_INTERNAL_BindGraphicsResources(metalCommandBuffer);

        for (Uint32 i = 0; i < drawCount; i += 1) {
            [metalCommandBuffer->renderEncoder
                drawIndexedPrimitives:SDLToMetal_PrimitiveType[primitiveType]
                            indexType:SDLToMetal_IndexType[metalCommandBuffer->indexElementSize]
                          indexBuffer:metalCommandBuffer->indexBuffer->handle
                    indexBufferOffset:metalCommandBuffer->indexBufferOffset
                       indirectBuffer:metalBuffer->handle
                 indirectBufferOffset:offsetInBytes + (stride * i)];
        }

        METAL_INTERNAL_TrackBuffer(metalCommandBuffer, metalBuffer);
    }
}

static void METAL_EndRenderPass(
    SDL_GpuCommandBuffer *commandBuffer)
{
    @autoreleasepool {
        MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
        [metalCommandBuffer->renderEncoder endEncoding];
        metalCommandBuffer->renderEncoder = nil;

        for (Uint32 i = 0; i < MAX_TEXTURE_SAMPLERS_PER_STAGE; i += 1) {
            metalCommandBuffer->vertexSamplers[i] = nil;
            metalCommandBuffer->vertexTextures[i] = nil;
            metalCommandBuffer->fragmentSamplers[i] = nil;
            metalCommandBuffer->fragmentTextures[i] = nil;
        }
        for (Uint32 i = 0; i < MAX_STORAGE_TEXTURES_PER_STAGE; i += 1) {
            metalCommandBuffer->vertexStorageTextures[i] = nil;
            metalCommandBuffer->fragmentStorageTextures[i] = nil;
        }
        for (Uint32 i = 0; i < MAX_STORAGE_BUFFERS_PER_STAGE; i += 1) {
            metalCommandBuffer->vertexStorageBuffers[i] = nil;
            metalCommandBuffer->fragmentStorageBuffers[i] = nil;
        }
    }
}

/* This function assumes that it's called from within an autorelease pool */
static void METAL_INTERNAL_PushUniformData(
    MetalCommandBuffer *metalCommandBuffer,
    SDL_GpuShaderStage shaderStage,
    Uint32 slotIndex,
    const void *data,
    Uint32 dataLengthInBytes)
{
    MetalUniformBuffer *metalUniformBuffer;
    Uint32 alignedDataLength;

    if (shaderStage == SDL_GPU_SHADERSTAGE_VERTEX) {
        if (metalCommandBuffer->vertexUniformBuffers[slotIndex] == NULL) {
            metalCommandBuffer->vertexUniformBuffers[slotIndex] = METAL_INTERNAL_AcquireUniformBufferFromPool(
                metalCommandBuffer);
        }
        metalUniformBuffer = metalCommandBuffer->vertexUniformBuffers[slotIndex];
    } else if (shaderStage == SDL_GPU_SHADERSTAGE_FRAGMENT) {
        if (metalCommandBuffer->fragmentUniformBuffers[slotIndex] == NULL) {
            metalCommandBuffer->fragmentUniformBuffers[slotIndex] = METAL_INTERNAL_AcquireUniformBufferFromPool(
                metalCommandBuffer);
        }
        metalUniformBuffer = metalCommandBuffer->fragmentUniformBuffers[slotIndex];
    } else if (shaderStage == SDL_GPU_SHADERSTAGE_COMPUTE) {
        if (metalCommandBuffer->computeUniformBuffers[slotIndex] == NULL) {
            metalCommandBuffer->computeUniformBuffers[slotIndex] = METAL_INTERNAL_AcquireUniformBufferFromPool(
                metalCommandBuffer);
        }
        metalUniformBuffer = metalCommandBuffer->computeUniformBuffers[slotIndex];
    } else {
        SDL_LogError(SDL_LOG_CATEGORY_GPU, "Unrecognized shader stage!");
        return;
    }

    alignedDataLength = METAL_INTERNAL_NextHighestAlignment(
        dataLengthInBytes,
        256);

    if (metalUniformBuffer->writeOffset + alignedDataLength >= UNIFORM_BUFFER_SIZE) {
        metalUniformBuffer = METAL_INTERNAL_AcquireUniformBufferFromPool(
            metalCommandBuffer);

        metalUniformBuffer->writeOffset = 0;
        metalUniformBuffer->drawOffset = 0;

        if (shaderStage == SDL_GPU_SHADERSTAGE_VERTEX) {
            metalCommandBuffer->vertexUniformBuffers[slotIndex] = metalUniformBuffer;
        } else if (shaderStage == SDL_GPU_SHADERSTAGE_FRAGMENT) {
            metalCommandBuffer->fragmentUniformBuffers[slotIndex] = metalUniformBuffer;
        } else if (shaderStage == SDL_GPU_SHADERSTAGE_COMPUTE) {
            metalCommandBuffer->computeUniformBuffers[slotIndex] = metalUniformBuffer;
        } else {
            SDL_LogError(SDL_LOG_CATEGORY_GPU, "Unrecognized shader stage!");
            return;
        }
    }

    metalUniformBuffer->drawOffset = metalUniformBuffer->writeOffset;

    SDL_memcpy(
        (metalUniformBuffer->handle).contents + metalUniformBuffer->writeOffset,
        data,
        dataLengthInBytes);

    metalUniformBuffer->writeOffset += alignedDataLength;

    if (shaderStage == SDL_GPU_SHADERSTAGE_VERTEX) {
        metalCommandBuffer->needVertexUniformBind = SDL_TRUE;
    } else if (shaderStage == SDL_GPU_SHADERSTAGE_FRAGMENT) {
        metalCommandBuffer->needFragmentUniformBind = SDL_TRUE;
    } else if (shaderStage == SDL_GPU_SHADERSTAGE_COMPUTE) {
        metalCommandBuffer->needComputeUniformBind = SDL_TRUE;
    } else {
        SDL_LogError(SDL_LOG_CATEGORY_GPU, "Unrecognized shader stage!");
    }
}

static void METAL_PushVertexUniformData(
    SDL_GpuCommandBuffer *commandBuffer,
    Uint32 slotIndex,
    const void *data,
    Uint32 dataLengthInBytes)
{
    @autoreleasepool {
        METAL_INTERNAL_PushUniformData(
            (MetalCommandBuffer *)commandBuffer,
            SDL_GPU_SHADERSTAGE_VERTEX,
            slotIndex,
            data,
            dataLengthInBytes);
    }
}

static void METAL_PushFragmentUniformData(
    SDL_GpuCommandBuffer *commandBuffer,
    Uint32 slotIndex,
    const void *data,
    Uint32 dataLengthInBytes)
{
    @autoreleasepool {
        METAL_INTERNAL_PushUniformData(
            (MetalCommandBuffer *)commandBuffer,
            SDL_GPU_SHADERSTAGE_FRAGMENT,
            slotIndex,
            data,
            dataLengthInBytes);
    }
}

/* Blit */

static SDL_GpuGraphicsPipeline *METAL_INTERNAL_FetchBlitPipeline(
    MetalRenderer *renderer,
    SDL_GpuTextureFormat destinationFormat)
{
    SDL_GpuGraphicsPipelineCreateInfo blitPipelineCreateInfo;
    SDL_GpuColorAttachmentDescription colorAttachmentDesc;
    SDL_GpuGraphicsPipeline *pipeline;

    /* FIXME: is there a better lock we can use? */
    SDL_LockMutex(renderer->submitLock);

    /* Try to use an existing pipeline */
    for (Uint32 i = 0; i < renderer->blitPipelineCount; i += 1) {
        if (renderer->blitPipelines[i].format == destinationFormat) {
            SDL_UnlockMutex(renderer->submitLock);
            return renderer->blitPipelines[i].pipeline;
        }
    }

    /* Create a new pipeline! */
    SDL_zero(blitPipelineCreateInfo);

    SDL_zero(colorAttachmentDesc);
    colorAttachmentDesc.format = destinationFormat;
    colorAttachmentDesc.blendState.blendEnable = 0;
    colorAttachmentDesc.blendState.colorWriteMask = 0xFF;

    blitPipelineCreateInfo.attachmentInfo.colorAttachmentDescriptions = &colorAttachmentDesc;
    blitPipelineCreateInfo.attachmentInfo.colorAttachmentCount = 1;

    blitPipelineCreateInfo.vertexShader = renderer->fullscreenVertexShader;
    blitPipelineCreateInfo.fragmentShader = renderer->blitFrom2DPixelShader;

    blitPipelineCreateInfo.multisampleState.sampleCount = SDL_GPU_SAMPLECOUNT_1;
    blitPipelineCreateInfo.multisampleState.sampleMask = 0xFFFFFFFF;

    blitPipelineCreateInfo.primitiveType = SDL_GPU_PRIMITIVETYPE_TRIANGLELIST;

    blitPipelineCreateInfo.blendConstants[0] = 1.0f;
    blitPipelineCreateInfo.blendConstants[1] = 1.0f;
    blitPipelineCreateInfo.blendConstants[2] = 1.0f;
    blitPipelineCreateInfo.blendConstants[3] = 1.0f;

    pipeline = METAL_CreateGraphicsPipeline(
        (SDL_GpuRenderer *)renderer,
        &blitPipelineCreateInfo);
    if (pipeline == NULL) {
        SDL_LogError(SDL_LOG_CATEGORY_GPU, "Failed to create blit pipeline!");
        SDL_UnlockMutex(renderer->submitLock);
        return NULL;
    }

    if (renderer->blitPipelineCount >= renderer->blitPipelineCapacity) {
        renderer->blitPipelineCapacity *= 2;
        renderer->blitPipelines = SDL_realloc(
            renderer->blitPipelines,
            sizeof(BlitPipeline) * renderer->blitPipelineCapacity);
    }
    renderer->blitPipelines[renderer->blitPipelineCount].pipeline = pipeline;
    renderer->blitPipelines[renderer->blitPipelineCount].format = destinationFormat;
    renderer->blitPipelineCount += 1;

    SDL_UnlockMutex(renderer->submitLock);
    return pipeline;
}

static void METAL_Blit(
    SDL_GpuCommandBuffer *commandBuffer,
    SDL_GpuTextureRegion *source,
    SDL_GpuTextureRegion *destination,
    SDL_GpuFilter filterMode,
    SDL_bool cycle)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
    MetalRenderer *renderer = (MetalRenderer *)metalCommandBuffer->renderer;
    MetalTextureContainer *destinationTextureContainer = (MetalTextureContainer *)destination->texture;
    SDL_GpuGraphicsPipeline *pipeline;
    SDL_GpuColorAttachmentInfo colorAttachmentInfo;
    SDL_GpuViewport viewport;
    SDL_GpuTextureSamplerBinding textureSamplerBinding;

    /* FIXME: cube copies? texture arrays? */

    pipeline = METAL_INTERNAL_FetchBlitPipeline(
        renderer,
        destinationTextureContainer->header.info.format);
    if (pipeline == NULL) {
        /* Drop the blit if the pipeline fetch failed! */
        return;
    }

    /* Unused */
    colorAttachmentInfo.clearColor.r = 0;
    colorAttachmentInfo.clearColor.g = 0;
    colorAttachmentInfo.clearColor.b = 0;
    colorAttachmentInfo.clearColor.a = 0;

    /* If the entire destination is blitted, we don't have to load */
    if (
        destinationTextureContainer->header.info.levelCount == 1 &&
        destination->w == destinationTextureContainer->header.info.width &&
        destination->h == destinationTextureContainer->header.info.height &&
        destination->d == destinationTextureContainer->header.info.depth) {
        colorAttachmentInfo.loadOp = SDL_GPU_LOADOP_DONT_CARE;
    } else {
        colorAttachmentInfo.loadOp = SDL_GPU_LOADOP_LOAD;
    }

    colorAttachmentInfo.storeOp = SDL_GPU_STOREOP_STORE;
    colorAttachmentInfo.texture = destination->texture;
    colorAttachmentInfo.layerOrDepthPlane = destination->layer;
    colorAttachmentInfo.mipLevel = destination->mipLevel;
    colorAttachmentInfo.cycle = cycle;

    METAL_BeginRenderPass(
        commandBuffer,
        &colorAttachmentInfo,
        1,
        NULL);

    viewport.x = (float)destination->x;
    viewport.y = (float)destination->y;
    viewport.w = (float)destination->w;
    viewport.h = (float)destination->h;
    viewport.minDepth = 0;
    viewport.maxDepth = 1;

    METAL_SetViewport(commandBuffer, &viewport);
    METAL_BindGraphicsPipeline(commandBuffer, pipeline);

    textureSamplerBinding.texture = source->texture;
    textureSamplerBinding.sampler = (filterMode == SDL_GPU_FILTER_NEAREST)
                                        ? renderer->blitNearestSampler
                                        : renderer->blitLinearSampler;

    METAL_BindFragmentSamplers(
        commandBuffer,
        0,
        &textureSamplerBinding,
        1);

    METAL_DrawPrimitives(commandBuffer, 0, 3);
    METAL_EndRenderPass(commandBuffer);
}

/* Compute State */

static void METAL_BeginComputePass(
    SDL_GpuCommandBuffer *commandBuffer,
    SDL_GpuStorageTextureReadWriteBinding *storageTextureBindings,
    Uint32 storageTextureBindingCount,
    SDL_GpuStorageBufferReadWriteBinding *storageBufferBindings,
    Uint32 storageBufferBindingCount)
{
    @autoreleasepool {
        MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
        MetalTextureContainer *textureContainer;
        MetalTexture *texture;
        id<MTLTexture> textureView;
        MetalBufferContainer *bufferContainer;
        MetalBuffer *buffer;

        metalCommandBuffer->computeEncoder = [metalCommandBuffer->handle computeCommandEncoder];

        for (Uint32 i = 0; i < storageTextureBindingCount; i += 1) {
            textureContainer = (MetalTextureContainer *)storageTextureBindings[i].texture;

            texture = METAL_INTERNAL_PrepareTextureForWrite(
                metalCommandBuffer->renderer,
                textureContainer,
                storageTextureBindings[i].cycle);

            METAL_INTERNAL_TrackTexture(metalCommandBuffer, texture);

            textureView = [texture->handle newTextureViewWithPixelFormat:SDLToMetal_SurfaceFormat[textureContainer->header.info.format]
                                                             textureType:SDLToMetal_TextureType[textureContainer->header.info.type]
                                                                  levels:NSMakeRange(storageTextureBindings[i].mipLevel, 1)
                                                                  slices:NSMakeRange(storageTextureBindings[i].layer, 1)];

            metalCommandBuffer->computeReadWriteTextures[i] = textureView;
            metalCommandBuffer->needComputeTextureBind = SDL_TRUE;
        }

        for (Uint32 i = 0; i < storageBufferBindingCount; i += 1) {
            bufferContainer = (MetalBufferContainer *)storageBufferBindings[i].buffer;

            buffer = METAL_INTERNAL_PrepareBufferForWrite(
                metalCommandBuffer->renderer,
                bufferContainer,
                storageBufferBindings[i].cycle);

            METAL_INTERNAL_TrackBuffer(
                metalCommandBuffer,
                buffer);

            metalCommandBuffer->computeReadWriteBuffers[i] = buffer->handle;
            metalCommandBuffer->needComputeBufferBind = SDL_TRUE;
        }
    }
}

static void METAL_BindComputePipeline(
    SDL_GpuCommandBuffer *commandBuffer,
    SDL_GpuComputePipeline *computePipeline)
{
    @autoreleasepool {
        MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
        MetalComputePipeline *pipeline = (MetalComputePipeline *)computePipeline;

        metalCommandBuffer->computePipeline = pipeline;

        [metalCommandBuffer->computeEncoder setComputePipelineState:pipeline->handle];

        for (Uint32 i = 0; i < pipeline->uniformBufferCount; i += 1) {
            if (metalCommandBuffer->computeUniformBuffers[i] == NULL) {
                metalCommandBuffer->computeUniformBuffers[i] = METAL_INTERNAL_AcquireUniformBufferFromPool(
                    metalCommandBuffer);
            }
        }

        metalCommandBuffer->needComputeUniformBind = SDL_TRUE;
    }
}

static void METAL_BindComputeStorageTextures(
    SDL_GpuCommandBuffer *commandBuffer,
    Uint32 firstSlot,
    SDL_GpuTexture **storageTextures,
    Uint32 bindingCount)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
    MetalTextureContainer *textureContainer;

    for (Uint32 i = 0; i < bindingCount; i += 1) {
        textureContainer = (MetalTextureContainer *)storageTextures[i];

        METAL_INTERNAL_TrackTexture(
            metalCommandBuffer,
            textureContainer->activeTexture);

        metalCommandBuffer->computeReadOnlyTextures[firstSlot + i] =
            textureContainer->activeTexture->handle;
    }

    metalCommandBuffer->needComputeTextureBind = SDL_TRUE;
}

static void METAL_BindComputeStorageBuffers(
    SDL_GpuCommandBuffer *commandBuffer,
    Uint32 firstSlot,
    SDL_GpuBuffer **storageBuffers,
    Uint32 bindingCount)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
    MetalBufferContainer *bufferContainer;

    for (Uint32 i = 0; i < bindingCount; i += 1) {
        bufferContainer = (MetalBufferContainer *)storageBuffers[i];

        METAL_INTERNAL_TrackBuffer(
            metalCommandBuffer,
            bufferContainer->activeBuffer);

        metalCommandBuffer->computeReadOnlyBuffers[firstSlot + i] =
            bufferContainer->activeBuffer->handle;
    }

    metalCommandBuffer->needComputeBufferBind = SDL_TRUE;
}

static void METAL_PushComputeUniformData(
    SDL_GpuCommandBuffer *commandBuffer,
    Uint32 slotIndex,
    const void *data,
    Uint32 dataLengthInBytes)
{
    @autoreleasepool {
        METAL_INTERNAL_PushUniformData(
            (MetalCommandBuffer *)commandBuffer,
            SDL_GPU_SHADERSTAGE_COMPUTE,
            slotIndex,
            data,
            dataLengthInBytes);
    }
}

static void METAL_DispatchCompute(
    SDL_GpuCommandBuffer *commandBuffer,
    Uint32 groupCountX,
    Uint32 groupCountY,
    Uint32 groupCountZ)
{
    @autoreleasepool {
        MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
        MTLSize threadgroups = MTLSizeMake(groupCountX, groupCountY, groupCountZ);
        MTLSize threadsPerThreadgroup = MTLSizeMake(
            metalCommandBuffer->computePipeline->threadCountX,
            metalCommandBuffer->computePipeline->threadCountY,
            metalCommandBuffer->computePipeline->threadCountZ);

        METAL_INTERNAL_BindComputeResources(metalCommandBuffer);

        [metalCommandBuffer->computeEncoder
             dispatchThreadgroups:threadgroups
            threadsPerThreadgroup:threadsPerThreadgroup];
    }
}

static void METAL_DispatchComputeIndirect(
    SDL_GpuCommandBuffer *commandBuffer,
    SDL_GpuBuffer *buffer,
    Uint32 offsetInBytes)
{
    @autoreleasepool {
        MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
        MetalBuffer *metalBuffer = ((MetalBufferContainer *)buffer)->activeBuffer;
        MTLSize threadsPerThreadgroup = MTLSizeMake(
            metalCommandBuffer->computePipeline->threadCountX,
            metalCommandBuffer->computePipeline->threadCountY,
            metalCommandBuffer->computePipeline->threadCountZ);

        METAL_INTERNAL_BindComputeResources(metalCommandBuffer);

        [metalCommandBuffer->computeEncoder
            dispatchThreadgroupsWithIndirectBuffer:metalBuffer->handle
                              indirectBufferOffset:offsetInBytes
                             threadsPerThreadgroup:threadsPerThreadgroup];

        METAL_INTERNAL_TrackBuffer(metalCommandBuffer, metalBuffer);
    }
}

static void METAL_EndComputePass(
    SDL_GpuCommandBuffer *commandBuffer)
{
    @autoreleasepool {
        MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
        [metalCommandBuffer->computeEncoder endEncoding];
        metalCommandBuffer->computeEncoder = nil;

        for (Uint32 i = 0; i < MAX_COMPUTE_WRITE_TEXTURES; i += 1) {
            metalCommandBuffer->computeReadWriteTextures[i] = nil;
        }
        for (Uint32 i = 0; i < MAX_COMPUTE_WRITE_BUFFERS; i += 1) {
            metalCommandBuffer->computeReadWriteBuffers[i] = nil;
        }
        for (Uint32 i = 0; i < MAX_STORAGE_TEXTURES_PER_STAGE; i += 1) {
            metalCommandBuffer->computeReadOnlyTextures[i] = nil;
        }
        for (Uint32 i = 0; i < MAX_STORAGE_BUFFERS_PER_STAGE; i += 1) {
            metalCommandBuffer->computeReadOnlyBuffers[i] = nil;
        }
    }
}

/* Fence Cleanup */

static void METAL_INTERNAL_ReleaseFenceToPool(
    MetalRenderer *renderer,
    MetalFence *fence)
{
    SDL_LockMutex(renderer->fenceLock);

    /* FIXME: Should this use EXPAND_IF_NEEDED? */
    if (renderer->availableFenceCount == renderer->availableFenceCapacity) {
        renderer->availableFenceCapacity *= 2;
        renderer->availableFences = SDL_realloc(
            renderer->availableFences,
            renderer->availableFenceCapacity * sizeof(MetalFence *));
    }
    renderer->availableFences[renderer->availableFenceCount] = fence;
    renderer->availableFenceCount += 1;

    SDL_UnlockMutex(renderer->fenceLock);
}

static void METAL_ReleaseFence(
    SDL_GpuRenderer *driverData,
    SDL_GpuFence *fence)
{
    METAL_INTERNAL_ReleaseFenceToPool(
        (MetalRenderer *)driverData,
        (MetalFence *)fence);
}

/* Cleanup */

static void METAL_INTERNAL_CleanCommandBuffer(
    MetalRenderer *renderer,
    MetalCommandBuffer *commandBuffer)
{
    Uint32 i;

    /* Reference Counting */
    for (i = 0; i < commandBuffer->usedBufferCount; i += 1) {
        (void)SDL_AtomicDecRef(&commandBuffer->usedBuffers[i]->referenceCount);
    }
    commandBuffer->usedBufferCount = 0;

    for (i = 0; i < commandBuffer->usedTextureCount; i += 1) {
        (void)SDL_AtomicDecRef(&commandBuffer->usedTextures[i]->referenceCount);
    }
    commandBuffer->usedTextureCount = 0;

    /* Uniform buffers are now available */

    SDL_LockMutex(renderer->acquireUniformBufferLock);

    for (i = 0; i < commandBuffer->usedUniformBufferCount; i += 1) {
        METAL_INTERNAL_ReturnUniformBufferToPool(
            renderer,
            commandBuffer->usedUniformBuffers[i]);
    }
    commandBuffer->usedUniformBufferCount = 0;

    SDL_UnlockMutex(renderer->acquireUniformBufferLock);

    /* Reset presentation */
    commandBuffer->windowDataCount = 0;

    /* Reset bindings */
    commandBuffer->indexBuffer = NULL;
    for (i = 0; i < MAX_TEXTURE_SAMPLERS_PER_STAGE; i += 1) {
        commandBuffer->vertexSamplers[i] = nil;
        commandBuffer->vertexTextures[i] = nil;
        commandBuffer->fragmentSamplers[i] = nil;
        commandBuffer->fragmentTextures[i] = nil;
    }
    for (i = 0; i < MAX_STORAGE_TEXTURES_PER_STAGE; i += 1) {
        commandBuffer->vertexStorageTextures[i] = nil;
        commandBuffer->fragmentStorageTextures[i] = nil;
        commandBuffer->computeReadOnlyTextures[i] = nil;
    }
    for (i = 0; i < MAX_STORAGE_BUFFERS_PER_STAGE; i += 1) {
        commandBuffer->vertexStorageBuffers[i] = nil;
        commandBuffer->fragmentStorageBuffers[i] = nil;
        commandBuffer->computeReadOnlyBuffers[i] = nil;
    }
    for (i = 0; i < MAX_COMPUTE_WRITE_TEXTURES; i += 1) {
        commandBuffer->computeReadWriteTextures[i] = nil;
    }
    for (i = 0; i < MAX_COMPUTE_WRITE_BUFFERS; i += 1) {
        commandBuffer->computeReadWriteBuffers[i] = nil;
    }

    /* The fence is now available (unless SubmitAndAcquireFence was called) */
    if (commandBuffer->autoReleaseFence) {
        METAL_ReleaseFence(
            (SDL_GpuRenderer *)renderer,
            (SDL_GpuFence *)commandBuffer->fence);
    }

    /* Return command buffer to pool */
    SDL_LockMutex(renderer->acquireCommandBufferLock);
    /* FIXME: Should this use EXPAND_IF_NEEDED? */
    if (renderer->availableCommandBufferCount == renderer->availableCommandBufferCapacity) {
        renderer->availableCommandBufferCapacity += 1;
        renderer->availableCommandBuffers = SDL_realloc(
            renderer->availableCommandBuffers,
            renderer->availableCommandBufferCapacity * sizeof(MetalCommandBuffer *));
    }
    renderer->availableCommandBuffers[renderer->availableCommandBufferCount] = commandBuffer;
    renderer->availableCommandBufferCount += 1;
    SDL_UnlockMutex(renderer->acquireCommandBufferLock);

    /* Remove this command buffer from the submitted list */
    for (i = 0; i < renderer->submittedCommandBufferCount; i += 1) {
        if (renderer->submittedCommandBuffers[i] == commandBuffer) {
            renderer->submittedCommandBuffers[i] = renderer->submittedCommandBuffers[renderer->submittedCommandBufferCount - 1];
            renderer->submittedCommandBufferCount -= 1;
        }
    }
}

/* This function assumes that it's called from within an autorelease pool */
static void METAL_INTERNAL_PerformPendingDestroys(
    MetalRenderer *renderer)
{
    Sint32 referenceCount = 0;
    Sint32 i;
    Uint32 j;

    for (i = renderer->bufferContainersToDestroyCount - 1; i >= 0; i -= 1) {
        referenceCount = 0;
        for (j = 0; j < renderer->bufferContainersToDestroy[i]->bufferCount; j += 1) {
            referenceCount += SDL_AtomicGet(&renderer->bufferContainersToDestroy[i]->buffers[j]->referenceCount);
        }

        if (referenceCount == 0) {
            METAL_INTERNAL_DestroyBufferContainer(
                renderer->bufferContainersToDestroy[i]);

            renderer->bufferContainersToDestroy[i] = renderer->bufferContainersToDestroy[renderer->bufferContainersToDestroyCount - 1];
            renderer->bufferContainersToDestroyCount -= 1;
        }
    }

    for (i = renderer->textureContainersToDestroyCount - 1; i >= 0; i -= 1) {
        referenceCount = 0;
        for (j = 0; j < renderer->textureContainersToDestroy[i]->textureCount; j += 1) {
            referenceCount += SDL_AtomicGet(&renderer->textureContainersToDestroy[i]->textures[j]->referenceCount);
        }

        if (referenceCount == 0) {
            METAL_INTERNAL_DestroyTextureContainer(
                renderer->textureContainersToDestroy[i]);

            renderer->textureContainersToDestroy[i] = renderer->textureContainersToDestroy[renderer->textureContainersToDestroyCount - 1];
            renderer->textureContainersToDestroyCount -= 1;
        }
    }
}

/* Fences */

static void METAL_WaitForFences(
    SDL_GpuRenderer *driverData,
    SDL_bool waitAll,
    SDL_GpuFence **pFences,
    Uint32 fenceCount)
{
    @autoreleasepool {
        MetalRenderer *renderer = (MetalRenderer *)driverData;
        SDL_bool waiting;

        if (waitAll) {
            for (Uint32 i = 0; i < fenceCount; i += 1) {
                while (!SDL_AtomicGet(&((MetalFence *)pFences[i])->complete)) {
                    /* Spin! */
                }
            }
        } else {
            waiting = 1;
            while (waiting) {
                for (Uint32 i = 0; i < fenceCount; i += 1) {
                    if (SDL_AtomicGet(&((MetalFence *)pFences[i])->complete) > 0) {
                        waiting = 0;
                        break;
                    }
                }
            }
        }

        METAL_INTERNAL_PerformPendingDestroys(renderer);
    }
}

static SDL_bool METAL_QueryFence(
    SDL_GpuRenderer *driverData,
    SDL_GpuFence *fence)
{
    MetalFence *metalFence = (MetalFence *)fence;
    return SDL_AtomicGet(&metalFence->complete) == 1;
}

/* Window and Swapchain Management */

static MetalWindowData *METAL_INTERNAL_FetchWindowData(SDL_Window *window)
{
    SDL_PropertiesID properties = SDL_GetWindowProperties(window);
    return (MetalWindowData *)SDL_GetPointerProperty(properties, WINDOW_PROPERTY_DATA, NULL);
}

static SDL_bool METAL_SupportsSwapchainComposition(
    SDL_GpuRenderer *driverData,
    SDL_Window *window,
    SDL_GpuSwapchainComposition swapchainComposition)
{
#ifndef SDL_PLATFORM_MACOS
    if (swapchainComposition == SDL_GPU_SWAPCHAINCOMPOSITION_HDR10_ST2048) {
        return SDL_FALSE;
    }
#endif

    if (@available(macOS 11.0, *)) {
        return SDL_TRUE;
    } else {
        return swapchainComposition != SDL_GPU_SWAPCHAINCOMPOSITION_HDR10_ST2048;
    }
}

/* This function assumes that it's called from within an autorelease pool */
static Uint8 METAL_INTERNAL_CreateSwapchain(
    MetalRenderer *renderer,
    MetalWindowData *windowData,
    SDL_GpuSwapchainComposition swapchainComposition,
    SDL_GpuPresentMode presentMode)
{
    CGColorSpaceRef colorspace;
    CGSize drawableSize;

    windowData->view = SDL_Metal_CreateView(windowData->window);
    windowData->drawable = nil;

    windowData->layer = (__bridge CAMetalLayer *)(SDL_Metal_GetLayer(windowData->view));
    windowData->layer.device = renderer->device;
    windowData->layer.framebufferOnly = false; /* Allow sampling swapchain textures, at the expense of performance */
#ifdef SDL_PLATFORM_MACOS
    windowData->layer.displaySyncEnabled = (presentMode != SDL_GPU_PRESENTMODE_IMMEDIATE);
#endif
    windowData->layer.pixelFormat = SDLToMetal_SurfaceFormat[SwapchainCompositionToFormat[swapchainComposition]];
#ifndef SDL_PLATFORM_TVOS
    windowData->layer.wantsExtendedDynamicRangeContent = (swapchainComposition != SDL_GPU_SWAPCHAINCOMPOSITION_SDR);
#endif

    colorspace = CGColorSpaceCreateWithName(SwapchainCompositionToColorSpace[swapchainComposition]);
    windowData->layer.colorspace = colorspace;
    CGColorSpaceRelease(colorspace);

    windowData->texture.handle = nil; /* This will be set in AcquireSwapchainTexture. */

    /* Set up the texture container */
    SDL_zero(windowData->textureContainer);
    windowData->textureContainer.canBeCycled = 0;
    windowData->textureContainer.activeTexture = &windowData->texture;
    windowData->textureContainer.textureCapacity = 1;
    windowData->textureContainer.textureCount = 1;
    windowData->textureContainer.header.info.format = SwapchainCompositionToFormat[swapchainComposition];
    windowData->textureContainer.header.info.levelCount = 1;
    windowData->textureContainer.header.info.depth = 1;
    windowData->textureContainer.header.info.type = SDL_GPU_TEXTURETYPE_2D;
    windowData->textureContainer.header.info.usageFlags = SDL_GPU_TEXTUREUSAGE_COLOR_TARGET_BIT | SDL_GPU_TEXTUREUSAGE_SAMPLER_BIT;

    drawableSize = windowData->layer.drawableSize;
    windowData->textureContainer.header.info.width = (Uint32)drawableSize.width;
    windowData->textureContainer.header.info.height = (Uint32)drawableSize.height;

    return 1;
}

static SDL_bool METAL_SupportsPresentMode(
    SDL_GpuRenderer *driverData,
    SDL_Window *window,
    SDL_GpuPresentMode presentMode)
{
    switch (presentMode) {
#ifdef SDL_PLATFORM_MACOS
    case SDL_GPU_PRESENTMODE_IMMEDIATE:
#endif
    case SDL_GPU_PRESENTMODE_VSYNC:
        return SDL_TRUE;
    default:
        return SDL_FALSE;
    }
}

static SDL_bool METAL_ClaimWindow(
    SDL_GpuRenderer *driverData,
    SDL_Window *window,
    SDL_GpuSwapchainComposition swapchainComposition,
    SDL_GpuPresentMode presentMode)
{
    @autoreleasepool {
        MetalRenderer *renderer = (MetalRenderer *)driverData;
        MetalWindowData *windowData = METAL_INTERNAL_FetchWindowData(window);

        if (windowData == NULL) {
            windowData = (MetalWindowData *)SDL_malloc(sizeof(MetalWindowData));
            windowData->window = window;

            if (METAL_INTERNAL_CreateSwapchain(renderer, windowData, swapchainComposition, presentMode)) {
                SDL_SetPointerProperty(SDL_GetWindowProperties(window), WINDOW_PROPERTY_DATA, windowData);

                SDL_LockMutex(renderer->windowLock);

                if (renderer->claimedWindowCount >= renderer->claimedWindowCapacity) {
                    renderer->claimedWindowCapacity *= 2;
                    renderer->claimedWindows = SDL_realloc(
                        renderer->claimedWindows,
                        renderer->claimedWindowCapacity * sizeof(MetalWindowData *));
                }
                renderer->claimedWindows[renderer->claimedWindowCount] = windowData;
                renderer->claimedWindowCount += 1;

                SDL_UnlockMutex(renderer->windowLock);

                return SDL_TRUE;
            } else {
                SDL_LogError(SDL_LOG_CATEGORY_GPU, "Could not create swapchain, failed to claim window!");
                SDL_free(windowData);
                return SDL_FALSE;
            }
        } else {
            SDL_LogWarn(SDL_LOG_CATEGORY_GPU, "Window already claimed!");
            return SDL_FALSE;
        }
    }
}

static void METAL_UnclaimWindow(
    SDL_GpuRenderer *driverData,
    SDL_Window *window)
{
    @autoreleasepool {
        MetalRenderer *renderer = (MetalRenderer *)driverData;
        MetalWindowData *windowData = METAL_INTERNAL_FetchWindowData(window);

        if (windowData == NULL) {
            return;
        }

        METAL_Wait(driverData);
        SDL_Metal_DestroyView(windowData->view);

        SDL_LockMutex(renderer->windowLock);
        for (Uint32 i = 0; i < renderer->claimedWindowCount; i += 1) {
            if (renderer->claimedWindows[i]->window == window) {
                renderer->claimedWindows[i] = renderer->claimedWindows[renderer->claimedWindowCount - 1];
                renderer->claimedWindowCount -= 1;
                break;
            }
        }
        SDL_UnlockMutex(renderer->windowLock);

        SDL_free(windowData);

        SDL_ClearProperty(SDL_GetWindowProperties(window), WINDOW_PROPERTY_DATA);
    }
}

static SDL_GpuTexture *METAL_AcquireSwapchainTexture(
    SDL_GpuCommandBuffer *commandBuffer,
    SDL_Window *window,
    Uint32 *pWidth,
    Uint32 *pHeight)
{
    @autoreleasepool {
        MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
        MetalWindowData *windowData;
        CGSize drawableSize;

        windowData = METAL_INTERNAL_FetchWindowData(window);
        if (windowData == NULL) {
            return NULL;
        }

        /* Get the drawable and its underlying texture */
        windowData->drawable = [windowData->layer nextDrawable];
        windowData->texture.handle = [windowData->drawable texture];

        /* Update the window size */
        drawableSize = windowData->layer.drawableSize;
        windowData->textureContainer.header.info.width = (Uint32)drawableSize.width;
        windowData->textureContainer.header.info.height = (Uint32)drawableSize.height;

        /* Send the dimensions to the out parameters. */
        *pWidth = (Uint32)drawableSize.width;
        *pHeight = (Uint32)drawableSize.height;

        /* Set up presentation */
        if (metalCommandBuffer->windowDataCount == metalCommandBuffer->windowDataCapacity) {
            metalCommandBuffer->windowDataCapacity += 1;
            metalCommandBuffer->windowDatas = SDL_realloc(
                metalCommandBuffer->windowDatas,
                metalCommandBuffer->windowDataCapacity * sizeof(MetalWindowData *));
        }
        metalCommandBuffer->windowDatas[metalCommandBuffer->windowDataCount] = windowData;
        metalCommandBuffer->windowDataCount += 1;

        /* Return the swapchain texture */
        return (SDL_GpuTexture *)&windowData->textureContainer;
    }
}

static SDL_GpuTextureFormat METAL_GetSwapchainTextureFormat(
    SDL_GpuRenderer *driverData,
    SDL_Window *window)
{
    MetalWindowData *windowData = METAL_INTERNAL_FetchWindowData(window);

    if (windowData == NULL) {
        SDL_LogError(SDL_LOG_CATEGORY_GPU, "Cannot get swapchain format, window has not been claimed!");
        return 0;
    }

    return windowData->textureContainer.header.info.format;
}

static SDL_bool METAL_SetSwapchainParameters(
    SDL_GpuRenderer *driverData,
    SDL_Window *window,
    SDL_GpuSwapchainComposition swapchainComposition,
    SDL_GpuPresentMode presentMode)
{
    @autoreleasepool {
        MetalWindowData *windowData = METAL_INTERNAL_FetchWindowData(window);
        CGColorSpaceRef colorspace;

        if (windowData == NULL) {
            SDL_LogError(SDL_LOG_CATEGORY_GPU, "Cannot set swapchain parameters, window has not been claimed!");
            return SDL_FALSE;
        }

        if (!METAL_SupportsSwapchainComposition(driverData, window, swapchainComposition)) {
            SDL_LogError(SDL_LOG_CATEGORY_GPU, "Swapchain composition not supported!");
            return SDL_FALSE;
        }

        if (!METAL_SupportsPresentMode(driverData, window, presentMode)) {
            SDL_LogError(SDL_LOG_CATEGORY_GPU, "Present mode not supported!");
            return SDL_FALSE;
        }

        METAL_Wait(driverData);

#ifdef SDL_PLATFORM_MACOS
        windowData->layer.displaySyncEnabled = (presentMode != SDL_GPU_PRESENTMODE_IMMEDIATE);
#endif
        windowData->layer.pixelFormat = SDLToMetal_SurfaceFormat[SwapchainCompositionToFormat[swapchainComposition]];
#ifndef SDL_PLATFORM_TVOS
        windowData->layer.wantsExtendedDynamicRangeContent = (swapchainComposition != SDL_GPU_SWAPCHAINCOMPOSITION_SDR);
#endif

        colorspace = CGColorSpaceCreateWithName(SwapchainCompositionToColorSpace[swapchainComposition]);
        windowData->layer.colorspace = colorspace;
        CGColorSpaceRelease(colorspace);

        windowData->textureContainer.header.info.format = SwapchainCompositionToFormat[swapchainComposition];

        return SDL_TRUE;
    }
}

/* Submission */

static void METAL_Submit(
    SDL_GpuCommandBuffer *commandBuffer)
{
    @autoreleasepool {
        MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
        MetalRenderer *renderer = metalCommandBuffer->renderer;

        SDL_LockMutex(renderer->submitLock);

        /* Enqueue present requests, if applicable */
        for (Uint32 i = 0; i < metalCommandBuffer->windowDataCount; i += 1) {
            [metalCommandBuffer->handle presentDrawable:metalCommandBuffer->windowDatas[i]->drawable];
            metalCommandBuffer->windowDatas[i]->drawable = nil;
        }

        /* Notify the fence when the command buffer has completed */
        [metalCommandBuffer->handle addCompletedHandler:^(id<MTLCommandBuffer> buffer) {
          SDL_AtomicIncRef(&metalCommandBuffer->fence->complete);
        }];

        /* Submit the command buffer */
        [metalCommandBuffer->handle commit];
        metalCommandBuffer->handle = nil;

        /* Mark the command buffer as submitted */
        if (renderer->submittedCommandBufferCount >= renderer->submittedCommandBufferCapacity) {
            renderer->submittedCommandBufferCapacity = renderer->submittedCommandBufferCount + 1;

            renderer->submittedCommandBuffers = SDL_realloc(
                renderer->submittedCommandBuffers,
                sizeof(MetalCommandBuffer *) * renderer->submittedCommandBufferCapacity);
        }
        renderer->submittedCommandBuffers[renderer->submittedCommandBufferCount] = metalCommandBuffer;
        renderer->submittedCommandBufferCount += 1;

        /* Check if we can perform any cleanups */
        for (Sint32 i = renderer->submittedCommandBufferCount - 1; i >= 0; i -= 1) {
            if (SDL_AtomicGet(&renderer->submittedCommandBuffers[i]->fence->complete)) {
                METAL_INTERNAL_CleanCommandBuffer(
                    renderer,
                    renderer->submittedCommandBuffers[i]);
            }
        }

        METAL_INTERNAL_PerformPendingDestroys(renderer);

        SDL_UnlockMutex(renderer->submitLock);
    }
}

static SDL_GpuFence *METAL_SubmitAndAcquireFence(
    SDL_GpuCommandBuffer *commandBuffer)
{
    MetalCommandBuffer *metalCommandBuffer = (MetalCommandBuffer *)commandBuffer;
    MetalFence *fence = metalCommandBuffer->fence;

    metalCommandBuffer->autoReleaseFence = 0;
    METAL_Submit(commandBuffer);

    return (SDL_GpuFence *)fence;
}

static void METAL_Wait(
    SDL_GpuRenderer *driverData)
{
    @autoreleasepool {
        MetalRenderer *renderer = (MetalRenderer *)driverData;
        MetalCommandBuffer *commandBuffer;

        /*
         * Wait for all submitted command buffers to complete.
         * Sort of equivalent to vkDeviceWaitIdle.
         */
        for (Uint32 i = 0; i < renderer->submittedCommandBufferCount; i += 1) {
            while (!SDL_AtomicGet(&renderer->submittedCommandBuffers[i]->fence->complete)) {
                /* Spin! */
            }
        }

        SDL_LockMutex(renderer->submitLock);

        for (Sint32 i = renderer->submittedCommandBufferCount - 1; i >= 0; i -= 1) {
            commandBuffer = renderer->submittedCommandBuffers[i];
            METAL_INTERNAL_CleanCommandBuffer(renderer, commandBuffer);
        }

        METAL_INTERNAL_PerformPendingDestroys(renderer);

        SDL_UnlockMutex(renderer->submitLock);
    }
}

/* Format Info */

static SDL_bool METAL_SupportsTextureFormat(
    SDL_GpuRenderer *driverData,
    SDL_GpuTextureFormat format,
    SDL_GpuTextureType type,
    SDL_GpuTextureUsageFlags usage)
{
    @autoreleasepool {
        MetalRenderer *renderer = (MetalRenderer *)driverData;

        /* Only depth textures can be used as... depth textures */
        if ((usage & SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET_BIT)) {
            if (!IsDepthFormat(format)) {
                return SDL_FALSE;
            }
        }

        switch (format) {
        /* Apple GPU exclusive */
        case SDL_GPU_TEXTUREFORMAT_B5G6R5:
        case SDL_GPU_TEXTUREFORMAT_B5G5R5A1:
        case SDL_GPU_TEXTUREFORMAT_B4G4R4A4:
            return [renderer->device supportsFamily:MTLGPUFamilyApple1];

        /* Requires BC compression support */
        case SDL_GPU_TEXTUREFORMAT_BC1:
        case SDL_GPU_TEXTUREFORMAT_BC2:
        case SDL_GPU_TEXTUREFORMAT_BC3:
        case SDL_GPU_TEXTUREFORMAT_BC7:
        case SDL_GPU_TEXTUREFORMAT_BC3_SRGB:
        case SDL_GPU_TEXTUREFORMAT_BC7_SRGB:
#ifdef SDL_PLATFORM_MACOS
            if (@available(macOS 11.0, *)) {
                return (
                    [renderer->device supportsBCTextureCompression] &&
                    !(usage & SDL_GPU_TEXTUREUSAGE_COLOR_TARGET_BIT));
            } else {
                return SDL_FALSE;
            }
#else
            /* FIXME: iOS 16.4+ allows these formats! */
            return SDL_FALSE;
#endif

        /* Requires D24S8 support */
        case SDL_GPU_TEXTUREFORMAT_D24_UNORM:
        case SDL_GPU_TEXTUREFORMAT_D24_UNORM_S8_UINT:
#ifdef SDL_PLATFORM_MACOS
            return [renderer->device isDepth24Stencil8PixelFormatSupported];
#else
            return SDL_FALSE;
#endif

        default:
            return SDL_TRUE;
        }
    }
}

/* Device Creation */

static SDL_bool METAL_PrepareDriver(SDL_VideoDevice *_this)
{
    /* FIXME: Add a macOS / iOS version check! Maybe support >= 10.14? */
    return (_this->Metal_CreateView != NULL);
}

static void METAL_INTERNAL_InitBlitResources(
    MetalRenderer *renderer)
{
    SDL_GpuShaderCreateInfo shaderModuleCreateInfo;
    SDL_GpuSamplerCreateInfo samplerCreateInfo;

    /* Allocate the dynamic blit pipeline list */
    renderer->blitPipelineCapacity = 1;
    renderer->blitPipelineCount = 0;
    renderer->blitPipelines = SDL_malloc(
        sizeof(BlitPipeline) * renderer->blitPipelineCapacity);

    /* Fullscreen vertex shader */
    SDL_zero(shaderModuleCreateInfo);
    shaderModuleCreateInfo.code = (Uint8 *)FullscreenVertexShader;
    shaderModuleCreateInfo.codeSize = sizeof(FullscreenVertexShader);
    shaderModuleCreateInfo.stage = SDL_GPU_SHADERSTAGE_VERTEX;
    shaderModuleCreateInfo.format = SDL_GPU_SHADERFORMAT_MSL;
    shaderModuleCreateInfo.entryPointName = "vs_main";

    renderer->fullscreenVertexShader = METAL_CreateShader(
        (SDL_GpuRenderer *)renderer,
        &shaderModuleCreateInfo);

    if (renderer->fullscreenVertexShader == NULL) {
        SDL_LogError(SDL_LOG_CATEGORY_GPU, "Failed to compile fullscreen vertex shader!");
    }

    /* Blit from 2D pixel shader */
    shaderModuleCreateInfo.code = (Uint8 *)BlitFrom2DFragmentShader;
    shaderModuleCreateInfo.codeSize = sizeof(BlitFrom2DFragmentShader);
    shaderModuleCreateInfo.stage = SDL_GPU_SHADERSTAGE_FRAGMENT;
    shaderModuleCreateInfo.entryPointName = "fs_main";
    shaderModuleCreateInfo.samplerCount = 1;

    renderer->blitFrom2DPixelShader = METAL_CreateShader(
        (SDL_GpuRenderer *)renderer,
        &shaderModuleCreateInfo);

    if (renderer->blitFrom2DPixelShader == NULL) {
        SDL_LogError(SDL_LOG_CATEGORY_GPU, "Failed to compile blit from 2D fragment shader!");
    }

    /* Create samplers */
    samplerCreateInfo.addressModeU = SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
    samplerCreateInfo.addressModeV = SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
    samplerCreateInfo.addressModeW = SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
    samplerCreateInfo.anisotropyEnable = 0;
    samplerCreateInfo.compareEnable = 0;
    samplerCreateInfo.magFilter = SDL_GPU_FILTER_NEAREST;
    samplerCreateInfo.minFilter = SDL_GPU_FILTER_NEAREST;
    samplerCreateInfo.mipmapMode = SDL_GPU_SAMPLERMIPMAPMODE_NEAREST;
    samplerCreateInfo.mipLodBias = 0.0f;
    samplerCreateInfo.minLod = 0;
    samplerCreateInfo.maxLod = 1000;

    renderer->blitNearestSampler = METAL_CreateSampler(
        (SDL_GpuRenderer *)renderer,
        &samplerCreateInfo);

    if (renderer->blitNearestSampler == NULL) {
        SDL_LogError(SDL_LOG_CATEGORY_GPU, "Failed to create blit nearest sampler!");
    }

    samplerCreateInfo.magFilter = SDL_GPU_FILTER_LINEAR;
    samplerCreateInfo.minFilter = SDL_GPU_FILTER_LINEAR;
    samplerCreateInfo.mipmapMode = SDL_GPU_SAMPLERMIPMAPMODE_LINEAR;

    renderer->blitLinearSampler = METAL_CreateSampler(
        (SDL_GpuRenderer *)renderer,
        &samplerCreateInfo);

    if (renderer->blitLinearSampler == NULL) {
        SDL_LogError(SDL_LOG_CATEGORY_GPU, "Failed to create blit linear sampler!");
    }
}

static void METAL_INTERNAL_DestroyBlitResources(
    SDL_GpuRenderer *driverData)
{
    MetalRenderer *renderer = (MetalRenderer *)driverData;

    METAL_ReleaseShader(driverData, renderer->fullscreenVertexShader);
    METAL_ReleaseShader(driverData, renderer->blitFrom2DPixelShader);

    METAL_ReleaseSampler(driverData, renderer->blitLinearSampler);
    METAL_ReleaseSampler(driverData, renderer->blitNearestSampler);

    for (Uint32 i = 0; i < renderer->blitPipelineCount; i += 1) {
        METAL_ReleaseGraphicsPipeline(
            driverData,
            renderer->blitPipelines[i].pipeline);
    }
    SDL_free(renderer->blitPipelines);
}

static SDL_GpuDevice *METAL_CreateDevice(SDL_bool debugMode, SDL_bool preferLowPower, SDL_PropertiesID props)
{
    @autoreleasepool {
        MetalRenderer *renderer;

        /* Allocate and zero out the renderer */
        renderer = (MetalRenderer *)SDL_calloc(1, sizeof(MetalRenderer));

        /* Create the Metal device and command queue */
#ifdef SDL_PLATFORM_MACOS
        if (preferLowPower) {
            NSArray<id<MTLDevice>> *devices = MTLCopyAllDevices();
            for (id<MTLDevice> device in devices) {
                if (device.isLowPower) {
                    renderer->device = device;
                    break;
                }
            }
        }
#endif
        if (renderer->device == NULL) {
            renderer->device = MTLCreateSystemDefaultDevice();
        }
        renderer->queue = [renderer->device newCommandQueue];

        /* Print driver info */
        SDL_LogInfo(SDL_LOG_CATEGORY_GPU, "SDL_Gpu Driver: Metal");
        SDL_LogInfo(
            SDL_LOG_CATEGORY_GPU,
            "Metal Device: %s",
            [renderer->device.name UTF8String]);

        /* Remember debug mode */
        renderer->debugMode = debugMode;

        /* Set up colorspace array */
        SwapchainCompositionToColorSpace[0] = kCGColorSpaceSRGB;
        SwapchainCompositionToColorSpace[1] = kCGColorSpaceSRGB;
        SwapchainCompositionToColorSpace[2] = kCGColorSpaceExtendedLinearSRGB;
        if (@available(macOS 11.0, *)) {
            SwapchainCompositionToColorSpace[3] = kCGColorSpaceITUR_2100_PQ;
        } else {
            SwapchainCompositionToColorSpace[3] = NULL;
        }

        /* Create mutexes */
        renderer->submitLock = SDL_CreateMutex();
        renderer->acquireCommandBufferLock = SDL_CreateMutex();
        renderer->acquireUniformBufferLock = SDL_CreateMutex();
        renderer->disposeLock = SDL_CreateMutex();
        renderer->fenceLock = SDL_CreateMutex();
        renderer->windowLock = SDL_CreateMutex();

        /* Create command buffer pool */
        METAL_INTERNAL_AllocateCommandBuffers(renderer, 2);

        /* Create fence pool */
        renderer->availableFenceCapacity = 2;
        renderer->availableFences = SDL_malloc(
            sizeof(MetalFence *) * renderer->availableFenceCapacity);

        /* Create uniform buffer pool */
        renderer->uniformBufferPoolCapacity = 32;
        renderer->uniformBufferPoolCount = 32;
        renderer->uniformBufferPool = SDL_malloc(
            renderer->uniformBufferPoolCapacity * sizeof(MetalUniformBuffer *));

        for (Uint32 i = 0; i < renderer->uniformBufferPoolCount; i += 1) {
            renderer->uniformBufferPool[i] = METAL_INTERNAL_CreateUniformBuffer(
                renderer,
                UNIFORM_BUFFER_SIZE);
        }

        /* Create deferred destroy arrays */
        renderer->bufferContainersToDestroyCapacity = 2;
        renderer->bufferContainersToDestroyCount = 0;
        renderer->bufferContainersToDestroy = SDL_malloc(
            renderer->bufferContainersToDestroyCapacity * sizeof(MetalBufferContainer *));

        renderer->textureContainersToDestroyCapacity = 2;
        renderer->textureContainersToDestroyCount = 0;
        renderer->textureContainersToDestroy = SDL_malloc(
            renderer->textureContainersToDestroyCapacity * sizeof(MetalTextureContainer *));

        /* Create claimed window list */
        renderer->claimedWindowCapacity = 1;
        renderer->claimedWindows = SDL_malloc(
            sizeof(MetalWindowData *) * renderer->claimedWindowCapacity);

        /* Initialize blit resources */
        METAL_INTERNAL_InitBlitResources(renderer);

        SDL_GpuDevice *result = SDL_malloc(sizeof(SDL_GpuDevice));
        ASSIGN_DRIVER(METAL)
        result->driverData = (SDL_GpuRenderer *)renderer;
        return result;
    }
}

SDL_GpuBootstrap MetalDriver = {
    "Metal",
    SDL_GPU_DRIVER_METAL,
    SDL_GPU_SHADERFORMAT_MSL | SDL_GPU_SHADERFORMAT_METALLIB,
    METAL_PrepareDriver,
    METAL_CreateDevice
};

#endif /*SDL_GPU_METAL*/
