/****************************************************************************
Copyright (c) 2020 Xiamen Yaji Software Co., Ltd.

http://www.cocos2d-x.org

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
****************************************************************************/
#include "MTLStd.h"

#include "MTLBuffer.h"
#include "MTLCommandBuffer.h"
#include "MTLCommands.h"
#include "MTLDescriptorSet.h"
#include "MTLDevice.h"
#include "MTLFence.h"
#include "MTLFramebuffer.h"
#include "MTLInputAssembler.h"
#include "MTLPipelineState.h"
#include "MTLQueue.h"
#include "MTLRenderPass.h"
#include "MTLSampler.h"
#include "MTLSemaphore.h"
#include "MTLShader.h"
#include "MTLTexture.h"
#include "TargetConditionals.h"

namespace tar {
    thread_local NSAutoreleasePool *cbAutoreleasePool = nullptr;
}

namespace cc {
namespace gfx {

CCMTLCommandBuffer::CCMTLCommandBuffer(Device *device)
: CommandBuffer(device), _mtlDevice((CCMTLDevice *)device), _mtlCommandQueue(id<MTLCommandQueue>(((CCMTLDevice *)device)->getMTLCommandQueue())), _mtkView((MTKView *)(((CCMTLDevice *)device)->getMTKView())) {
    const auto setCount = device->bindingMappingInfo().bufferOffsets.size();
    _GPUDescriptorSets.resize(setCount);
    _dynamicOffsets.resize(setCount);
    _indirectDrawSuppotred = _mtlDevice->isIndirectDrawSupported();
}

bool CCMTLCommandBuffer::initialize(const CommandBufferInfo &info)
{
    _type = info.type;
    _queue = info.queue;
    return true;
}

void CCMTLCommandBuffer::destroy()
{
    if (tar::cbAutoreleasePool)
    {
        [tar::cbAutoreleasePool release];
        tar::cbAutoreleasePool = nullptr;
    }
}

id<CAMetalDrawable> CCMTLCommandBuffer::getCurrentDrawable()
{
    if (!_currDrawable)
    {
        CAMetalLayer *layer = (CAMetalLayer*)_mtlDevice->getMTLLayer();
        _currDrawable = [[layer nextDrawable] retain];
    }
    return _currDrawable;
}

bool CCMTLCommandBuffer::isRenderingEntireDrawable(const Rect &rect, const CCMTLRenderPass *renderPass)
{
    const int num = renderPass->getColorRenderTargetNums();
    if (num == 0)
    {
        return true;
    }
    const auto &renderTargetSize = renderPass->getRenderTargetSizes()[0];
    return rect.x == 0 && rect.y == 0 && rect.width == renderTargetSize.x && rect.height == renderTargetSize.y;
}

void CCMTLCommandBuffer::begin(RenderPass *renderPass, uint subpass, Framebuffer *frameBuffer, int submitIndex) {
    if (_commandBufferBegan) return;

    tar::cbAutoreleasePool = [[NSAutoreleasePool alloc] init];
//    CC_LOG_INFO("%d CB POOL: %p ALLOCED for %p", [NSThread currentThread], tar::cbAutoreleasePool,  this);

    _isSecondary = renderPass != nullptr && _mtlCommandBuffer;
    if (!_isSecondary)
    {
        // Sub command buffer for parallel shouldn't request any command buffer
        _mtlCommandBuffer = [[_mtlCommandQueue commandBuffer] retain];
        [_mtlCommandBuffer enqueue];
    }
    _numTriangles = 0;
    _numDrawCalls = 0;
    _numInstances = 0;

    _GPUDescriptorSets.assign(_GPUDescriptorSets.size(), nullptr);
    for (auto &dynamicOffset : _dynamicOffsets)
    {
        dynamicOffset.clear();
    }
    _firstDirtyDescriptorSet = UINT_MAX;
    _commandBufferBegan = true;
}

void CCMTLCommandBuffer::end() {
    if (!_commandBufferBegan) return;
    _commandBufferBegan = false;

    if (_isSecondary)
    {
        // Secondary command buffer should end encoding here
        _commandEncoder.endEncoding();
    }

bool CCMTLCommandBuffer::isRenderingEntireDrawable(const Rect &rect, const CCMTLRenderPass *renderPass) {
    const int num = renderPass->getColorRenderTargetNums();
    if (num == 0) {
        return true;
    }
//    CC_LOG_INFO("%d CB POOL: %p RELEASED for %p", [NSThread currentThread], tar::cbAutoreleasePool, this);
    if (tar::cbAutoreleasePool)
    {
        [tar::cbAutoreleasePool drain];
        tar::cbAutoreleasePool = nullptr;
    }
}

void CCMTLCommandBuffer::beginRenderPass(RenderPass *renderPass, Framebuffer *fbo, const Rect &renderArea, const Color *colors, float depth, int stencil, uint32_t secondaryCBCount, const CommandBuffer *const *secondaryCBs)
{
    // Sub CommandBuffer shouldn't call begin render pass
    if (_isSecondary)
    {
        return;
    }

    auto isOffscreen = static_cast<CCMTLFramebuffer *>(fbo)->isOffscreen();
    if (!isOffscreen) {
        static_cast<CCMTLRenderPass *>(renderPass)->setColorAttachment(0, _mtkView.currentDrawable.texture, 0);
        static_cast<CCMTLRenderPass *>(renderPass)->setDepthStencilAttachment(_mtkView.depthStencilTexture, 0);
    }
    MTLRenderPassDescriptor *mtlRenderPassDescriptor = static_cast<CCMTLRenderPass *>(renderPass)->getMTLRenderPassDescriptor();
    if (!isRenderingEntireDrawable(renderArea, static_cast<CCMTLRenderPass *>(renderPass)))
    {
        // Metal doesn't apply the viewports and scissors to renderpass load-action clearing.
        mu::clearRenderArea(_mtlDevice, _mtlCommandBuffer, renderPass, renderArea, colors, depth, stencil);
    } else {
        const auto &colorAttachments = renderPass->getColorAttachments();
        const auto colorAttachmentCount = colorAttachments.size();
        for (size_t slot = 0u; slot < colorAttachmentCount; slot++) {
            mtlRenderPassDescriptor.colorAttachments[slot].clearColor = mu::toMTLClearColor(colors[slot]);
            mtlRenderPassDescriptor.colorAttachments[slot].loadAction = colorAttachments[slot].loadOp == LoadOp::CLEAR ? MTLLoadActionClear : MTLLoadActionLoad;
        }

        mtlRenderPassDescriptor.depthAttachment.clearDepth = depth;
        mtlRenderPassDescriptor.stencilAttachment.clearStencil = stencil;
    }

    if (count > 0)
    {
        _parallelEncoder = [[_mtlCommandBuffer parallelRenderCommandEncoderWithDescriptor:mtlRenderPassDescriptor] retain];
        // Create command encoders from parallel encoder and assign to command buffers
        for (uint i = 0u; i < count; ++i)
        {
            CCMTLCommandBuffer *cmdBuff = (CCMTLCommandBuffer *)cmdBuffs[i];
            cmdBuff->_commandEncoder.initialize(_parallelEncoder);
            cmdBuff->_mtlCommandBuffer = _mtlCommandBuffer;
        }
    }
    else
    {
        _commandEncoder.initialize(_mtlCommandBuffer, mtlRenderPassDescriptor);
    }
    _commandEncoder.setViewport(renderArea);
    _commandEncoder.setScissor(renderArea);
}

void CCMTLCommandBuffer::endRenderPass()
{
    if (_parallelEncoder)
    {
        [_parallelEncoder endEncoding];
        [_parallelEncoder release];
        _parallelEncoder = nil;
    }
    else
    {
        _commandEncoder.endEncoding();
    }
}

void CCMTLCommandBuffer::bindPipelineState(PipelineState *pso) {
    _gpuPipelineState = static_cast<CCMTLPipelineState *>(pso)->getGPUPipelineState();
    _mtlPrimitiveType = _gpuPipelineState->primitiveType;

#ifndef TARGET_OS_SIMULATOR
    if (@available(iOS 11.0, macOS 10.11))
    {
        [_mtlEncoder setDepthClipMode:_gpuPipelineState->depthClipMode];
    }
#endif
    [_mtlEncoder setTriangleFillMode:_gpuPipelineState->fillMode];
    [_mtlEncoder setRenderPipelineState:_gpuPipelineState->mtlRenderPipelineState];

    if (_gpuPipelineState->mtlDepthStencilState)
    {
        _commandEncoder.setStencilFrontBackReferenceValue(_gpuPipelineState->stencilRefFront, _gpuPipelineState->stencilRefBack);
        _commandEncoder.setDepthStencilState(_gpuPipelineState->mtlDepthStencilState);
    }
}

void CCMTLCommandBuffer::bindDescriptorSet(uint set, DescriptorSet *descriptorSet, uint dynamicOffsetCount, const uint *dynamicOffsets)
{
    CCASSERT(set < _GPUDescriptorSets.size(), "Invalid set index");
    if (dynamicOffsetCount)
    {
        _dynamicOffsets[set].assign(dynamicOffsets, dynamicOffsets + dynamicOffsetCount);
        if (set < _firstDirtyDescriptorSet) _firstDirtyDescriptorSet = set;
    }

    auto gpuDescriptorSet = static_cast<CCMTLDescriptorSet *>(descriptorSet)->gpuDescriptorSet();
    if (_GPUDescriptorSets[set] != gpuDescriptorSet)
    {
        _GPUDescriptorSets[set] = gpuDescriptorSet;
        if (set < _firstDirtyDescriptorSet) _firstDirtyDescriptorSet = set;
    }
}

void CCMTLCommandBuffer::bindInputAssembler(InputAssembler *ia) {
    if (ia) {
        _inputAssembler = static_cast<CCMTLInputAssembler *>(ia);
        if (_inputAssembler->getIndexBuffer())
        {
            _gpuIndexBuffer.mtlBuffer = static_cast<CCMTLBuffer *>(_inputAssembler->getIndexBuffer())->getMTLBuffer();
            _gpuIndexBuffer.stride = _inputAssembler->getIndexBuffer()->getStride();
            _indexType = static_cast<CCMTLBuffer *>(_inputAssembler->getIndexBuffer())->getIndexType();
        }

        if (_inputAssembler->getIndirectBuffer())
        {
            _gpuIndirectBuffer.mtlBuffer = static_cast<CCMTLBuffer *>(_inputAssembler->getIndirectBuffer())->getMTLBuffer();
            _gpuIndirectBuffer.count = _inputAssembler->getIndirectBuffer()->getCount();
        }
    }
}

void CCMTLCommandBuffer::setViewport(const Viewport &vp)
{
    _commandEncoder.setViewport(vp);
}

void CCMTLCommandBuffer::setScissor(const Rect &rect)
{
    _commandEncoder.setScissor(rect);
}

void CCMTLCommandBuffer::setLineWidth(const float width) {
    CC_LOG_WARNING("Metal doesn't support setting line width.");
}

void CCMTLCommandBuffer::setDepthBias(float constant, float clamp, float slope)
{
    _commandEncoder.setDepthBias(constant, clamp, slope);
}

void CCMTLCommandBuffer::setBlendConstants(const Color &constants)
{
    _commandEncoder.setBlendColor(constants);
}

void CCMTLCommandBuffer::setDepthBound(float minBounds, float maxBounds) {
    CC_LOG_ERROR("Metal doesn't support setting depth bound.");
}

void CCMTLCommandBuffer::setStencilWriteMask(StencilFace face, uint mask) {
    CC_LOG_ERROR("Don't support change stencil write mask here.");
}

void CCMTLCommandBuffer::setStencilCompareMask(StencilFace face, int ref, uint mask) {
    CC_LOG_ERROR("Don't support change stencil compare mask here.");
}

void CCMTLCommandBuffer::draw(InputAssembler *ia) {
    if (_firstDirtyDescriptorSet < _GPUDescriptorSets.size()) {
        bindDescriptorSets();
    }

    const auto indirectBuffer = static_cast<CCMTLBuffer *>(ia->getIndirectBuffer());
    const auto indexBuffer = static_cast<CCMTLBuffer *>(ia->getIndexBuffer());
    auto mtlEncoder = _commandEncoder.getMTLEncoder();
    if (_type == CommandBufferType::PRIMARY || _type == CommandBufferType::SECONDARY)
    {
        if (indirectBuffer)
        {
            uint count = indirectBuffer->getCount();
            const auto &drawInfos = indirectBuffer->getDrawInfos();
            _numDrawCalls += count;
            for (uint i = 0; i < count; ++i)
            {
                const auto &drawInfo = drawInfos[i];

    if (_type == CommandBufferType::PRIMARY || _type == CommandBufferType::SECONDARY)
    {
        if (indirectBuffer)
        {
            const auto indirectMTLBuffer = indirectBuffer->getMTLBuffer();

            if (_indirectDrawSuppotred)
            {
                ++_numDrawCalls;
                if (indirectBuffer->isDrawIndirectByIndex())
                {
                    [mtlEncoder drawIndexedPrimitives:_mtlPrimitiveType
                                            indexType:_indexType
                                          indexBuffer:indexBuffer->getMTLBuffer()
                                    indexBufferOffset:0
                                       indirectBuffer:indirectMTLBuffer
                                 indirectBufferOffset:0];
                }
                else
                {
                    [mtlEncoder drawPrimitives:_mtlPrimitiveType
                                indirectBuffer:indirectMTLBuffer
                          indirectBufferOffset:0];
                }
            }
            else
            {
                uint stride = indirectBuffer->getStride();
                uint offset = 0;
                uint drawInfoCount = indirectBuffer->getCount();
                const auto &drawInfos = indirectBuffer->getDrawInfos();
                _numDrawCalls += drawInfoCount;

                for (uint i = 0; i < drawInfoCount; ++i)
                {
                    const auto &drawInfo = drawInfos[i];
                    offset += drawInfo.firstIndex * stride;
                    if (indirectBuffer->isDrawIndirectByIndex())
                    {
                        if (drawInfo.instanceCount == 0)
                        {
                            [mtlEncoder drawIndexedPrimitives:_mtlPrimitiveType
                                                   indexCount:drawInfo.indexCount
                                                    indexType:_indexType
                                                  indexBuffer:indexBuffer->getMTLBuffer()
                                            indexBufferOffset:offset];
                        }
                        else
                        {
                            [mtlEncoder drawIndexedPrimitives:_mtlPrimitiveType
                                                   indexCount:drawInfo.indexCount
                                                    indexType:_indexType
                                                  indexBuffer:indexBuffer->getMTLBuffer()
                                            indexBufferOffset:offset
                                                instanceCount:drawInfo.instanceCount];
                        }
                    }
                    else
                    {
                        if (drawInfo.instanceCount == 0)
                        {
                            [mtlEncoder drawPrimitives:_mtlPrimitiveType
                                           vertexStart:drawInfo.firstIndex
                                           vertexCount:drawInfo.vertexCount];
                        }
                        else
                        {
                            [mtlEncoder drawPrimitives:_mtlPrimitiveType
                                           vertexStart:drawInfo.firstIndex
                                           vertexCount:drawInfo.vertexCount
                                         instanceCount:drawInfo.instanceCount];
                        }
                    }
                }
            }
        } else {
            DrawInfo drawInfo;
            static_cast<CCMTLInputAssembler *>(ia)->extractDrawInfo(drawInfo);
            if (drawInfo.indexCount > 0)
            {
                uint offset = 0;
                offset += drawInfo.firstIndex * indexBuffer->getStride();
                if (drawInfo.instanceCount == 0)
                {
                    [mtlEncoder drawIndexedPrimitives:_mtlPrimitiveType
                                           indexCount:drawInfo.indexCount
                                            indexType:_indexType
                                          indexBuffer:indexBuffer->getMTLBuffer()
                                    indexBufferOffset:offset];
                }
                else
                {
                    [mtlEncoder drawIndexedPrimitives:_mtlPrimitiveType
                                           indexCount:drawInfo.indexCount
                                            indexType:_indexType
                                          indexBuffer:indexBuffer->getMTLBuffer()
                                    indexBufferOffset:offset
                                        instanceCount:drawInfo.instanceCount];
                }
            }
            else if (drawInfo.vertexCount)
            {
                if (drawInfo.instanceCount == 0)
                {
                    [mtlEncoder drawPrimitives:_mtlPrimitiveType
                                   vertexStart:drawInfo.firstIndex
                                   vertexCount:drawInfo.vertexCount];
                }
                else
                {
                    [mtlEncoder drawPrimitives:_mtlPrimitiveType
                                   vertexStart:drawInfo.firstIndex
                                   vertexCount:drawInfo.vertexCount
                                 instanceCount:drawInfo.instanceCount];
                }
            }
            _numInstances += drawInfo.instanceCount;
            _numDrawCalls++;
            if (_gpuPipelineState) {
                uint indexCount = drawInfo.indexCount ? drawInfo.indexCount : drawInfo.vertexCount;
                switch (_mtlPrimitiveType) {
                    case MTLPrimitiveTypeTriangle:
                        _numTriangles += indexCount / 3 * std::max(drawInfo.instanceCount, 1u);
                        break;
                    case MTLPrimitiveTypeTriangleStrip:
                        _numTriangles += (indexCount - 2) * std::max(drawInfo.instanceCount, 1u);
                        break;
                    default: break;
                }
            }
        }

    } else if (_type == CommandBufferType::SECONDARY) {
        CC_LOG_ERROR("CommandBufferType::SECONDARY not implemented.");
    } else {
        CC_LOG_ERROR("Command 'draw' must be recorded inside a render pass.");
    }
}

void CCMTLCommandBuffer::updateBuffer(Buffer *buff, const void *data, uint size) {
    if (!buff) {
        CC_LOG_ERROR("CCMTLCommandBuffer::updateBuffer: buffer is nullptr.");
        return;
    }

    CCMTLGPUBuffer stagingBuffer;
    stagingBuffer.size = size;
    _mtlDevice->gpuStagingBufferPool()->alloc(&stagingBuffer);
    memcpy(stagingBuffer.mappedData, data, size);
    id<MTLBlitCommandEncoder> encoder = [_mtlCommandBuffer blitCommandEncoder];
    [encoder copyFromBuffer:stagingBuffer.mtlBuffer
               sourceOffset:stagingBuffer.startOffset
                   toBuffer:((CCMTLBuffer *)buff)->getMTLBuffer()
          destinationOffset:0
                       size:size];
    [encoder endEncoding];
}

void CCMTLCommandBuffer::copyBuffersToTexture(const uint8_t *const *buffers, Texture *texture, const BufferTextureCopy *regions, uint count) {
    if (!texture) {
        CC_LOG_ERROR("CCMTLCommandBuffer::copyBufferToTexture: texture is nullptr");
        return;
    }

    uint totalSize = 0;
    vector<uint> bufferSize(count);
    vector<CCMTLGPUBufferImageCopy> stagingRegions(count);
    auto format = texture->getFormat();
    CCMTLTexture *mtlTexture = static_cast<CCMTLTexture *>(texture);
    auto convertedFormat = mtlTexture->getConvertedFormat();
    for (size_t i = 0; i < count; i++) {
        const auto &region = regions[i];
        auto &stagingRegion = stagingRegions[i];
        auto w = region.buffStride > 0 ? region.buffStride : region.texExtent.width;
        auto h = region.buffTexHeight > 0 ? region.buffTexHeight : region.texExtent.height;
        bufferSize[i] = w * h;
        stagingRegion.sourceBytesPerRow = mu::getBytesPerRow(convertedFormat, w);
        stagingRegion.sourceBytesPerImage = FormatSize(convertedFormat, w, h, region.texExtent.depth);
        stagingRegion.sourceSize = {w, h, region.texExtent.depth};
        stagingRegion.destinationSlice = region.texSubres.baseArrayLayer;
        stagingRegion.destinationLevel = region.texSubres.mipLevel;
        stagingRegion.destinationOrigin =
        {
            static_cast<uint>(region.texOffset.x),
            static_cast<uint>(region.texOffset.y),
            static_cast<uint>(region.texOffset.z)
        };
        totalSize += stagingRegion.sourceBytesPerImage;
    }

    size_t offset = 0;
    id<MTLBlitCommandEncoder> encoder = [_mtlCommandBuffer blitCommandEncoder];
    id<MTLTexture> dstTexture = mtlTexture->getMTLTexture();
    const bool isArrayTexture = mtlTexture->isArray();
    for (size_t i = 0; i < count; i++) {
        const auto &stagingRegion = stagingRegions[i];
        const auto convertedData = mu::convertData(buffers[i], bufferSize[i], format);
        const auto sourceBytesPerImage = isArrayTexture ? stagingRegion.sourceBytesPerImage : 0;
        MTLRegion region = {stagingRegion.destinationOrigin, stagingRegion.sourceSize};
        auto bytesPerRow = mtlTexture->isPVRTC() ? 0 : stagingRegion.sourceBytesPerRow;
        auto bytesPerImage = mtlTexture->isPVRTC() ? 0 : sourceBytesPerImage;
        [dstTexture replaceRegion:region
                      mipmapLevel:stagingRegion.destinationLevel
                            slice:stagingRegion.destinationSlice
                        withBytes:convertedData
                      bytesPerRow:bytesPerRow
                    bytesPerImage:bytesPerImage];

        offset += stagingRegion.sourceBytesPerImage;
        if (convertedData != buffers[i])
        {
            CC_FREE(convertedData);
        }
    }
    if (texture->getFlags() & TextureFlags::GEN_MIPMAP && mu::pixelFormatIsColorRenderable(convertedFormat)) {
        [encoder generateMipmapsForTexture:dstTexture];
    }
    [encoder endEncoding];
}

void CCMTLCommandBuffer::execute(const CommandBuffer *const *commandBuffs, uint32_t count) {
    for (uint i = 0; i < count; ++i) {
        auto commandBuffer = static_cast<const CCMTLCommandBuffer *>(commandBuffs[i]);
        _numDrawCalls += commandBuffer->_numDrawCalls;
        _numInstances += commandBuffer->_numInstances;
        _numTriangles += commandBuffer->_numTriangles;
    }
}

void CCMTLCommandBuffer::bindDescriptorSets() {
    auto &vertexBuffers = _inputAssembler->getVertexBuffers();
    for (const auto &bindingInfo : _gpuPipelineState->vertexBufferBindingInfo) {
        auto index = std::get<0>(bindingInfo);
        auto stream = std::get<1>(bindingInfo);
        static_cast<CCMTLBuffer *>(vertexBuffers[stream])->encodeBuffer(_commandEncoder, 0, index, ShaderStageFlagBit::VERTEX);
    }

    const auto &dynamicOffsetIndices = _gpuPipelineState->gpuPipelineLayout->dynamicOffsetIndices;
    const auto &blocks = _gpuPipelineState->gpuShader->blocks;
    for (const auto &iter : blocks) {
        const auto &block = iter.second;

        const auto gpuDescriptorSet = _GPUDescriptorSets[block.set];
        const auto descriptorIndex = gpuDescriptorSet->descriptorIndices->at(block.binding);
        const auto &gpuDescriptor = gpuDescriptorSet->gpuDescriptors[descriptorIndex];
        if (!gpuDescriptor.buffer) {
            CC_LOG_ERROR("Buffer binding %s at set %d binding %d is not bounded.", block.name.c_str(), block.set, block.binding);
            continue;
        }

        const auto &dynamicOffset = dynamicOffsetIndices[block.set];
        auto dynamicOffsetIndex = (block.binding < dynamicOffset.size()) ? dynamicOffset[block.binding] : -1;
        if (gpuDescriptor.buffer) {
            uint offset = (dynamicOffsetIndex >= 0) ? _dynamicOffsets[block.set][dynamicOffsetIndex] : 0;
            gpuDescriptor.buffer->encodeBuffer(_commandEncoder,
                                               offset,
                                               block.mappedBinding,
                                               block.stages);
        }
    }

    const auto &samplers = _gpuPipelineState->gpuShader->samplers;
    for (const auto &iter : samplers)
    {
        const auto &sampler = iter.second;

        const auto gpuDescriptorSet = _GPUDescriptorSets[sampler.set];
        const auto descriptorIndex = gpuDescriptorSet->descriptorIndices->at(sampler.binding);
        const auto &gpuDescriptor = gpuDescriptorSet->gpuDescriptors[descriptorIndex];

        if (!gpuDescriptor.texture || !gpuDescriptor.sampler) {
            CC_LOG_ERROR("Sampler binding %s at set %d binding %d is not bounded.", sampler.name.c_str(), sampler.set, sampler.binding);
            continue;
        }

        if (sampler.stages & ShaderStageFlagBit::VERTEX)
        {
            [_mtlEncoder setVertexTexture:gpuDescriptor.texture->getMTLTexture()
                                  atIndex:sampler.textureBinding];
            [_mtlEncoder setVertexSamplerState:gpuDescriptor.sampler->getMTLSamplerState()
                                       atIndex:sampler.samplerBinding];
        }

        if (sampler.stages & ShaderStageFlagBit::FRAGMENT)
        {
            [_mtlEncoder setFragmentTexture:gpuDescriptor.texture->getMTLTexture()
                                    atIndex:sampler.textureBinding];
            [_mtlEncoder setFragmentSamplerState:gpuDescriptor.sampler->getMTLSamplerState()
                                         atIndex:sampler.samplerBinding];
        }
    }
}

} // namespace gfx
} // namespace cc
