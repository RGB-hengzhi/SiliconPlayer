#import "MetalRenderBridge.h"
#include <mpv/client.h>
#include <mpv/render.h>
#include <mpv/render_mtl.h>
#include <math.h>

#ifndef MPV_RENDER_API_TYPE_METAL
#error Compile this bridge against the pinned Metal fork headers, not stock render.h.
#endif

static const NSUInteger SPReceiptCapacity = 128;
static void *SPRenderQueueKey = &SPRenderQueueKey;
@class SPMetalState;

@interface SPObservedMetalLayer : CAMetalLayer
@property (nonatomic, weak) SPMetalState *observer;
@end

@interface SPMetalState : NSObject {
    mpv_render_context *_context; // The serial queue exclusively owns this pointer.
    SPObservedMetalLayer *_layer;
    dispatch_queue_t _queue;
    NSLock *_lock;
    NSUUID *_identity;
    CGSize _size;
    CGFloat _scale;
    NSTimeInterval _lastRequestedAt;
    NSTimeInterval _ticketRequestedAt;
    uint64_t _generation;
    uint64_t _attemptSequence;
    uint64_t _acquisitionSequence;
    uint64_t _droppedReceipts;
    uint64_t _latePresentedCallbacks;
    uint64_t _positivePresentedTimes;
    BOOL _scheduled;
    BOOL _closing;
    BOOL _closed;
    BOOL _force;
    BOOL _callbackUnregistered;
    BOOL _contextFreed;
    BOOL _configurationSuspended;
    NSUUID *_ticket;
    NSDictionary *_activeAttempt;
    NSDictionary *_lastAttempt;
    NSMutableArray<NSMutableDictionary *> *_drawables;
    NSString *_firstError;
}
- (instancetype)initWithHandle:(mpv_handle *)handle layer:(SPObservedMetalLayer *)layer status:(int32_t *)status;
- (BOOL)requestSize:(CGSize)size scale:(CGFloat)scale force:(BOOL)force ticket:(NSUUID *)ticket;
- (void)wakeup;
- (void)acquired:(id<CAMetalDrawable>)drawable;
- (void)presented:(id<MTLDrawable>)drawable acquisition:(uint64_t)acquisition;
- (NSDictionary *)diagnostics;
- (BOOL)close;
- (NSUUID *)identity;
- (void)drain;
- (BOOL)beginConfiguration;
- (void)endConfiguration;
- (void)renderSize:(CGSize)size scale:(CGFloat)scale force:(BOOL)force ticket:(NSUUID *)ticket generation:(uint64_t)generation requestedAt:(NSTimeInterval)requestedAt;
@end

@implementation SPObservedMetalLayer
- (id<CAMetalDrawable>)nextDrawable {
    id<CAMetalDrawable> drawable = [super nextDrawable];
    if (drawable) [self.observer acquired:drawable];
    return drawable;
}
@end

static void SPWakeup(void *opaque) {
    // No AppKit, client API or render API runs inside the mpv callback.
    [(__bridge SPMetalState *)opaque wakeup];
}

@implementation SPMetalState
- (instancetype)initWithHandle:(mpv_handle *)handle layer:(SPObservedMetalLayer *)layer status:(int32_t *)status {
    self = [super init];
    if (!self) { *status = MPV_ERROR_NOMEM; return nil; }
    _layer = layer; _lock = [NSLock new]; _identity = [NSUUID UUID];
    _queue = dispatch_queue_create("local.siliconplayer.render.metal", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(_queue, SPRenderQueueKey, (__bridge void *)self, NULL);
    _scale = 1; _drawables = [NSMutableArray new];
    layer.observer = self;
    __block int result = MPV_ERROR_UNINITIALIZED;
    dispatch_sync(_queue, ^{
        @autoreleasepool {
            mpv_metal_init_params metal = {
                .layer = (__bridge void *)self->_layer,
                .metal_device = (__bridge void *)self->_layer.device,
            };
            int advanced = 1;
            mpv_render_param params[] = {
                {MPV_RENDER_PARAM_API_TYPE, (void *)MPV_RENDER_API_TYPE_METAL},
                {MPV_RENDER_PARAM_METAL_INIT_PARAMS, &metal},
                {MPV_RENDER_PARAM_ADVANCED_CONTROL, &advanced},
                {MPV_RENDER_PARAM_INVALID, NULL},
            };
            result = mpv_render_context_create(&self->_context, handle, params);
            if (result >= 0 && self->_context) {
                mpv_render_context_set_update_callback(self->_context, SPWakeup, (__bridge void *)self);
            } else if (self->_context) {
                mpv_render_context_free(self->_context); self->_context = NULL;
            }
        }
    });
    *status = result >= 0 && !_context ? MPV_ERROR_UNINITIALIZED : result;
    if (result < 0 || !_context) { layer.observer = nil; return nil; }
    return self;
}
- (void)recordErrorLocked:(NSString *)error {
    if (!_firstError) _firstError = [error copy];
}
- (BOOL)requestSize:(CGSize)size scale:(CGFloat)scale force:(BOOL)force ticket:(NSUUID *)ticket {
    [_lock lock];
    if (_closing || !isfinite(size.width) || !isfinite(size.height) ||
        !isfinite(scale) || scale <= 0 || size.width < 0 || size.height < 0 ||
        size.width > 16384 || size.height > 16384 || (ticket && _ticket)) {
        [_lock unlock]; return NO;
    }
    if (_generation == UINT64_MAX) {
        [self recordErrorLocked:@"请求序号已达上限"]; [_lock unlock]; return NO;
    }
    _size = size; _scale = scale; _force |= force;
    _lastRequestedAt = NSProcessInfo.processInfo.systemUptime;
    if (ticket) { _ticket = ticket; _ticketRequestedAt = _lastRequestedAt; }
    _generation++;
    BOOL enqueue = !_scheduled && !_configurationSuspended;
    if (enqueue) _scheduled = YES;
    [_lock unlock];
    if (enqueue) dispatch_async(_queue, ^{ [self drain]; });
    return YES;
}
- (void)wakeup {
    [_lock lock];
    if (_closing || _generation == UINT64_MAX) {
        if (_generation == UINT64_MAX) [self recordErrorLocked:@"请求序号已达上限"];
        [_lock unlock]; return;
    }
    _generation++; _lastRequestedAt = NSProcessInfo.processInfo.systemUptime;
    BOOL enqueue = !_scheduled && !_configurationSuspended;
    if (enqueue) _scheduled = YES;
    [_lock unlock];
    if (enqueue) dispatch_async(_queue, ^{ [self drain]; });
}
- (void)drain {
    while (YES) {
        @autoreleasepool {
            [_lock lock];
            if (_closing || _configurationSuspended) { _scheduled = NO; [_lock unlock]; return; }
            uint64_t generation = _generation;
            CGSize size = _size; CGFloat scale = _scale;
            BOOL force = _force; _force = NO;
            NSUUID *ticket = _ticket; _ticket = nil;
            NSTimeInterval requestedAt = ticket ? _ticketRequestedAt : _lastRequestedAt;
            [_lock unlock];
            [self renderSize:size scale:scale force:force ticket:ticket generation:generation requestedAt:requestedAt];
            [_lock lock];
            if (_closing || _configurationSuspended || generation == _generation) {
                _scheduled = NO; [_lock unlock]; return;
            }
            [_lock unlock];
        }
    }
}
- (void)renderSize:(CGSize)size scale:(CGFloat)scale force:(BOOL)force ticket:(NSUUID *)ticket generation:(uint64_t)generation requestedAt:(NSTimeInterval)requestedAt {
    if (!_context) return;
    // Always service advanced-control work, including screenshot tasks with flags=0.
    uint64_t flags = mpv_render_context_update(_context);
    if (!force && !(flags & MPV_RENDER_UPDATE_FRAME)) return;
    BOOL positive = size.width > 0 && size.height > 0;
    [_lock lock];
    if (_attemptSequence == UINT64_MAX) {
        [self recordErrorLocked:@"渲染序号已达上限"]; [_lock unlock]; return;
    }
    uint64_t sequence = ++_attemptSequence;
    NSTimeInterval startedAt = NSProcessInfo.processInfo.systemUptime;
    _activeAttempt = @{ @"rendererID": _identity.UUIDString,
        @"attemptSequence": @(sequence), @"requestGeneration": @(generation),
        @"ticket": ticket.UUIDString ?: @"", @"forced": @(force),
        @"updateFlags": @(flags), @"requestedAt": @(requestedAt), @"attemptStartedAt": @(startedAt),
        @"requestedWidth": @(size.width), @"requestedHeight": @(size.height),
        @"requestedScale": @(scale) };
    [_lock unlock];
    // No AppKit reads occur here. All mutable layer render state has one queue owner.
    if (positive) { _layer.contentsScale = scale; _layer.drawableSize = size; }
    int block = 0, flip = 0, skip = !positive;
    mpv_render_param params[] = {
        {MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, &block},
        {MPV_RENDER_PARAM_FLIP_Y, &flip},
        {MPV_RENDER_PARAM_SKIP_RENDERING, &skip},
        {MPV_RENDER_PARAM_INVALID, NULL},
    };
    int result = mpv_render_context_render(_context, params);
    NSTimeInterval returnedAt = NSProcessInfo.processInfo.systemUptime;
    mpv_render_context_report_swap(_context);
    NSTimeInterval reportedAt = NSProcessInfo.processInfo.systemUptime;
    [_lock lock];
    NSMutableDictionary *attempt = [_activeAttempt mutableCopy];
    attempt[@"apiReturn"] = @(result); attempt[@"apiReturnedAt"] = @(returnedAt);
    attempt[@"reportedSwapAt"] = @(reportedAt); attempt[@"skippedZeroSize"] = @(!positive);
    // Return0 is not GPU success: this fork has WARN-only render/submit failure paths.
    attempt[@"gpuSuccessClaim"] = @NO; attempt[@"displayedPixelsClaim"] = @NO;
    _lastAttempt = [attempt copy]; _activeAttempt = nil;
    for (NSMutableDictionary *row in _drawables) {
        if ([row[@"attemptSequence"] unsignedLongLongValue] == sequence) {
            row[@"apiReturn"] = @(result); row[@"apiReturnedAt"] = @(returnedAt);
            row[@"reportedSwapAt"] = @(reportedAt);
        }
    }
    if (result < 0) [self recordErrorLocked:@"Metal 渲染调用失败"];
    [_lock unlock];
}
- (void)acquired:(id<CAMetalDrawable>)drawable {
    [_lock lock];
    if (_acquisitionSequence == UINT64_MAX) {
        [self recordErrorLocked:@"Drawable 序号已达上限"]; [_lock unlock]; return;
    }
    uint64_t acquisition = ++_acquisitionSequence;
    NSMutableDictionary *row = [_activeAttempt mutableCopy] ?: [NSMutableDictionary new];
    row[@"acquisitionSequence"] = @(acquisition); row[@"rendererID"] = _identity.UUIDString;
    row[@"associatedRenderAttempt"] = @(_activeAttempt != nil);
    row[@"drawableID"] = @(drawable.drawableID);
    row[@"textureWidth"] = @(drawable.texture.width); row[@"textureHeight"] = @(drawable.texture.height);
    row[@"pixelFormat"] = @(drawable.texture.pixelFormat);
    row[@"deviceRegistryID"] = @(drawable.texture.device.registryID);
    row[@"acquiredAt"] = @(NSProcessInfo.processInfo.systemUptime);
    row[@"wantsEDR"] = @(_layer.wantsExtendedDynamicRangeContent);
    CGColorSpaceRef color = _layer.colorspace;
    CFStringRef name = color ? CGColorSpaceCopyName(color) : NULL;
    row[@"colorSpace"] = name ? (__bridge NSString *)name : @"";
    if (name) CFRelease(name);
    row[@"presentedCallback"] = @NO; row[@"presentedTime"] = NSNull.null;
    if (_drawables.count == SPReceiptCapacity) { [_drawables removeObjectAtIndex:0]; _droppedReceipts++; }
    [_drawables addObject:row];
    [_lock unlock];
    __weak SPMetalState *weakSelf = self;
    [drawable addPresentedHandler:^(id<MTLDrawable> presented) {
        [weakSelf presented:presented acquisition:acquisition];
    }];
}
- (void)presented:(id<MTLDrawable>)drawable acquisition:(uint64_t)acquisition {
    double time = drawable.presentedTime;
    [_lock lock];
    if (_closed) _latePresentedCallbacks++;
    if (isfinite(time) && time > 0) _positivePresentedTimes++;
    for (NSMutableDictionary *row in _drawables) {
        if ([row[@"acquisitionSequence"] unsignedLongLongValue] == acquisition) {
            row[@"presentedCallback"] = @YES;
            row[@"callbackObservedAt"] = @(NSProcessInfo.processInfo.systemUptime);
            row[@"presentedTimeFinite"] = @(isfinite(time));
            row[@"presentedTime"] = isfinite(time) ? @(time) : (id)NSNull.null;
            row[@"callbackAfterClose"] = @(_closed); break;
        }
    }
    [_lock unlock];
}
- (NSDictionary *)diagnostics {
    [_lock lock];
    NSMutableArray *rows = [NSMutableArray arrayWithCapacity:_drawables.count];
    for (NSDictionary *row in _drawables) [rows addObject:[row copy]];
    NSDictionary *result = @{ @"schema": @"siliconplayer.metal-consumer.v1",
        @"rendererID": _identity.UUIDString, @"closed": @(_closed), @"closing": @(_closing),
        @"renderContextFreed": @(_contextFreed), @"callbackUnregistered": @(_callbackUnregistered),
        @"attemptCount": @(_attemptSequence), @"acquisitionCount": @(_acquisitionSequence),
        @"positivePresentedTimes": @(_positivePresentedTimes), @"latePresentedCallbacks": @(_latePresentedCallbacks),
        @"receiptCapacity": @(SPReceiptCapacity), @"droppedReceipts": @(_droppedReceipts),
        @"lastAttempt": _lastAttempt ?: (id)NSNull.null, @"drawables": rows,
        @"firstError": _firstError ?: (id)NSNull.null,
        @"gpuSuccessClaim": @NO, @"physicalHDRClaim": @NO };
    [_lock unlock]; return result;
}
- (NSUUID *)identity { return _identity; }
- (BOOL)beginConfiguration {
    if (dispatch_get_specific(SPRenderQueueKey) == (__bridge void *)self) return NO;
    [_lock lock];
    if (_closing || _configurationSuspended) { [_lock unlock]; return NO; }
    _configurationSuspended = YES; [_lock unlock];
    // Drain prior rendering before the caller changes client color properties.
    dispatch_sync(_queue, ^{});
    return YES;
}
- (void)endConfiguration {
    [_lock lock]; _configurationSuspended = NO; [_lock unlock];
    [self wakeup];
}
- (BOOL)close {
    // Blocking close must never run on its own render queue.
    if (dispatch_get_specific(SPRenderQueueKey) == (__bridge void *)self) return NO;
    [_lock lock];
    if (_closed) { [_lock unlock]; return YES; }
    _closing = YES; _ticket = nil;
    [_lock unlock];
    dispatch_sync(_queue, ^{
        @autoreleasepool {
            if (self->_context) {
                mpv_render_context_set_update_callback(self->_context, NULL, NULL);
                [self->_lock lock]; self->_callbackUnregistered = YES; [self->_lock unlock];
                // The actual Metal swapchain destroy waits for its in-flight GPU command buffers.
                mpv_render_context_free(self->_context); self->_context = NULL;
                [self->_lock lock]; self->_contextFreed = YES; [self->_lock unlock];
            }
        }
    });
    [_lock lock]; _scheduled = NO; _closed = YES; [_lock unlock];
    _layer.observer = nil;
    // A later presented handler only weakly references this tombstoned state.
    return YES;
}
@end

CAMetalLayer *SPMetalMakeObservedLayer(id<MTLDevice> device) {
    SPObservedMetalLayer *layer = [SPObservedMetalLayer new];
    layer.device = device; layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer.maximumDrawableCount = 3; layer.framebufferOnly = NO;
    layer.allowsNextDrawableTimeout = YES; layer.displaySyncEnabled = YES;
    layer.presentsWithTransaction = NO; layer.wantsExtendedDynamicRangeContent = NO;
    return layer;
}
SPMetalSessionRef SPMetalSessionCreate(void *handle, CAMetalLayer *layer, int32_t *status) {
    if (!handle || !status || ![layer isKindOfClass:SPObservedMetalLayer.class] || !layer.device) {
        if (status) *status = MPV_ERROR_INVALID_PARAMETER; return NULL;
    }
    SPMetalState *state = [[SPMetalState alloc] initWithHandle:handle layer:(SPObservedMetalLayer *)layer status:status];
    return state ? CFBridgingRetain(state) : NULL;
}
bool SPMetalSessionRequest(SPMetalSessionRef state, CGSize size, CGFloat scale, bool force, NSUUID *ticket) {
    return [(__bridge SPMetalState *)state requestSize:size scale:scale force:force ticket:ticket];
}
bool SPMetalSessionBeginConfiguration(SPMetalSessionRef state) { return [(__bridge SPMetalState *)state beginConfiguration]; }
void SPMetalSessionEndConfiguration(SPMetalSessionRef state) { [(__bridge SPMetalState *)state endConfiguration]; }
NSUUID *SPMetalSessionIdentity(SPMetalSessionRef state) { return [(__bridge SPMetalState *)state identity]; }
NSDictionary *SPMetalSessionDiagnostics(SPMetalSessionRef state) { return [(__bridge SPMetalState *)state diagnostics]; }
bool SPMetalSessionClose(SPMetalSessionRef state) { return [(__bridge SPMetalState *)state close]; }
void SPMetalSessionDestroy(SPMetalSessionRef state) {
    // Preserve the state if a caller violates the queue contract; never free live callbacks.
    if ([(__bridge SPMetalState *)state close]) { (void)CFBridgingRelease(state); }
}
