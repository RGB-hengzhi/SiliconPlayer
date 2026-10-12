#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

NS_ASSUME_NONNULL_BEGIN

/// Owns one render context. The caller retains its layer until Destroy returns.
/// This is an application bridge over the pinned fork's real render_mtl.h.
typedef const void *SPMetalSessionRef;

FOUNDATION_EXPORT CAMetalLayer *SPMetalMakeObservedLayer(id<MTLDevice> device);
FOUNDATION_EXPORT SPMetalSessionRef _Nullable SPMetalSessionCreate(
    void *mpvHandle, CAMetalLayer *layer, int32_t *outStatus);
FOUNDATION_EXPORT bool SPMetalSessionRequest(SPMetalSessionRef session,
    CGSize pixelSize, CGFloat scale, bool force, NSUUID * _Nullable ticket);
/// Main-thread client configuration may run between Begin/End; no client API on the render queue.
FOUNDATION_EXPORT bool SPMetalSessionBeginConfiguration(SPMetalSessionRef session);
FOUNDATION_EXPORT void SPMetalSessionEndConfiguration(SPMetalSessionRef session);
FOUNDATION_EXPORT NSUUID *SPMetalSessionIdentity(SPMetalSessionRef session);
FOUNDATION_EXPORT NSDictionary<NSString *, id> *SPMetalSessionDiagnostics(SPMetalSessionRef session);
FOUNDATION_EXPORT bool SPMetalSessionClose(SPMetalSessionRef session);
FOUNDATION_EXPORT void SPMetalSessionDestroy(SPMetalSessionRef session);

NS_ASSUME_NONNULL_END
