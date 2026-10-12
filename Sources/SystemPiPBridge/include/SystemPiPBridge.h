#import <AppKit/AppKit.h>
#include <stdint.h>
NS_ASSUME_NONNULL_BEGIN
typedef NS_ENUM(NSInteger, SPPiPEvent) {
    SPPiPEventStarted, SPPiPEventWillClose, SPPiPEventClosed, SPPiPEventFailed,
    SPPiPEventPlay, SPPiPEventPause, SPPiPEventStop, SPPiPEventSkip, SPPiPEventRedraw
};
/// Main-thread, installed-system-framework adapter. No player/audio is created.
@interface SPSystemPiPBridge : NSObject
@property(nonatomic, readonly) BOOL available;
@property(nonatomic, readonly, nullable) NSString *unavailableReason;
/// Bounded, address/path-redacted operation and exception diagnostics.
@property(nonatomic, readonly) NSDictionary<NSString *, id> *diagnostics;
@property(nonatomic, copy, nullable) void (^onEvent)(SPPiPEvent, uint64_t, double, NSString * _Nullable);
- (BOOL)presentView:(NSView *)view originWindow:(nullable NSWindow *)window
        aspectRatio:(NSSize)ratio playing:(BOOL)playing generation:(uint64_t)generation
        NS_SWIFT_NAME(present(view:originWindow:aspectRatio:playing:generation:));
- (void)dismissGeneration:(uint64_t)generation NS_SWIFT_NAME(dismiss(generation:));
- (void)updatePlaying:(BOOL)playing NS_SWIFT_NAME(update(playing:));
/// Detach the actual video from all system-PiP containers before returning true.
/// Does not claim a normal close callback or successful animation completion.
- (BOOL)forceDetachGeneration:(uint64_t)generation NS_SWIFT_NAME(forceDetach(generation:));
@end
/// Captures and restores one actual video-view attachment, under ObjC exception
/// guards. The host and view stay alive until restoration/teardown completes.
@interface SPSystemPiPAttachment : NSObject
@property(nonatomic, readonly) NSView *videoView;
@property(nonatomic, readonly) NSView *host;
@property(nonatomic, readonly, getter=isRestored) BOOL restored;
@property(nonatomic, readonly) NSDictionary<NSString *, id> *diagnostics;
- (nullable instancetype)initWithVideoView:(NSView *)view host:(NSView *)host
    NS_SWIFT_NAME(init(videoView:host:));
- (BOOL)prepareForPiP;
- (BOOL)restore;
@end
NS_ASSUME_NONNULL_END
