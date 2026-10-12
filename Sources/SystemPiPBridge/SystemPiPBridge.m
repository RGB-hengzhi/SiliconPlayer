// Original adapter; API knowledge from IINA GPLv3 commit
// b81da0a3576356bb69da43187fef3c155b921eb7 (see Docs/Prototypes/PiP-0.5).
// Loads, never copies or bundles, Apple's installed private PIP framework.
#import "SystemPiPBridge.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#include <math.h>

static NSString *SPDiagnosticText(NSString *input) {
    if(!input)return @"";
    if([input lengthOfBytesUsingEncoding:NSUTF8StringEncoding]>4096)return @"[oversized exception reason omitted]";
    NSString *text=[[input componentsSeparatedByCharactersInSet:NSCharacterSet.controlCharacterSet] componentsJoinedByString:@" "];
    NSRegularExpression *credentials=[NSRegularExpression regularExpressionWithPattern:@"(?i)\\b(authorization|cookie|bearer|token|signature|password|credential|secret)\\b" options:0 error:nil];
    if([credentials firstMatchInString:text options:0 range:NSMakeRange(0,text.length)])return @"[credential-bearing exception omitted]";
    NSRegularExpression *urls=[NSRegularExpression regularExpressionWithPattern:@"(?i)\\b(?:https?|file|ytdl|ftp|smb)://[^\\s\\\"'<>]*" options:0 error:nil];
    text=[urls stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0,text.length) withTemplate:@"[URL omitted]"];
    NSRegularExpression *paths=[NSRegularExpression regularExpressionWithPattern:@"(?<![A-Za-z0-9])/(?:[^\\s\\\"'<>])+" options:0 error:nil];
    text=[paths stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0,text.length) withTemplate:@"[path omitted]"];
    return [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding]<=2048?text:@"[oversized exception reason omitted]";
}
static NSDictionary *SPExceptionDiagnostic(NSString *stage, NSException *exception) {
    return @{@"stage":stage?:@"unknown",@"exceptionName":SPDiagnosticText(exception.name),@"reason":SPDiagnosticText(exception.reason)};
}

static BOOL SPMethod(Class cls, NSString *selector, const char *arg) {
    NSMethodSignature *s=[cls instanceMethodSignatureForSelector:NSSelectorFromString(selector)];
    if(!s || s.numberOfArguments!=3 || strcmp(s.methodReturnType,@encode(void)))return NO;
    const char *type=[s getArgumentTypeAtIndex:2];
    return arg[0]=='@' ? type[0]=='@' : strcmp(type,arg)==0;
}
static void SPObject(id object, NSString *selector, id value) {
    ((void (*)(id,SEL,id))objc_msgSend)(object,NSSelectorFromString(selector),value);
}
static NSDictionary *SPRectGeometry(NSRect value) {
    return @{@"x":@(value.origin.x),@"y":@(value.origin.y),@"width":@(value.size.width),@"height":@(value.size.height)};
}
static NSDictionary *SPViewGeometry(NSView *view) {
    if(!view)return @{};
    return @{@"class":NSStringFromClass(view.class),@"frame":SPRectGeometry(view.frame),
      @"bounds":SPRectGeometry(view.bounds),@"visibleRect":SPRectGeometry(view.visibleRect),
      @"autoresizingMask":@(view.autoresizingMask),@"autoresizesSubviews":@(view.autoresizesSubviews),
      @"translatesAutoresizingMask":@(view.translatesAutoresizingMaskIntoConstraints)};
}
@class SPContent, SPDelegate, SPVideoContainer;
@interface SPSystemPiPBridge ()
@property(nonatomic) Class controllerClass;
@property(nonatomic) void *framework;
@property(nonatomic, readwrite) BOOL available;
@property(nonatomic, readwrite, nullable) NSString *unavailableReason;
@property(nonatomic, strong) NSViewController *controller;
@property(nonatomic, strong) SPContent *content;
@property(nonatomic, strong) SPDelegate *proxy;
@property(nonatomic, weak) NSWindow *originWindow;
@property(nonatomic, weak) NSWindow *observedPanel;
@property(nonatomic, strong) NSView *video;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic) uint64_t generation;
@property(nonatomic) BOOL exitRequested;
@property(nonatomic) BOOL dismissIssued;
@property(nonatomic) BOOL nativeWillClose;
@property(nonatomic) BOOL nativeCloseConfirmed;
@property(nonatomic) uint64_t dismissalGeneration;
@property(nonatomic) NSUInteger dismissRequestCount;
@property(nonatomic) NSUInteger dismissAttemptCount;
@property(nonatomic) NSUInteger dismissSuppressedCount;
@property(nonatomic) NSUInteger dismissDeferredCount;
@property(nonatomic) NSUInteger dismissExceptionCount;
@property(nonatomic) BOOL started;
@property(nonatomic, copy) NSString *operationStage;
@property(nonatomic, strong) NSDictionary *lastFailure;
@property(nonatomic) NSUInteger presentationAttempts;
@property(nonatomic) NSUInteger containerLayoutCount;
@property(nonatomic) NSUInteger videoFrameChangeCount;
@property(nonatomic, strong) NSDictionary *lastGeometry;
- (void)emit:(SPPiPEvent)event generation:(uint64_t)ticket value:(double)value reason:(nullable NSString *)reason;
- (void)observe:(uint64_t)ticket;
- (void)recordObservedStart:(uint64_t)ticket windowClass:(NSString *)windowClass;
- (void)closed:(uint64_t)ticket;
- (NSDictionary *)geometrySnapshot;
@end
/// PIP.framework resizes its presented root view. The root must participate in
/// that autoresizing, independently of the original host's video child mask.
@interface SPVideoContainer : NSView
@property(nonatomic, weak) SPSystemPiPBridge *bridge;
@property(nonatomic) uint64_t generation;
@property(nonatomic) BOOL synchronizing;
- (void)synchronizeVideoFrame;
@end
@implementation SPVideoContainer
- (void)synchronizeVideoFrame {
    SPSystemPiPBridge *bridge=self.bridge;
    if(self.synchronizing || !bridge || bridge.generation!=self.generation || bridge.video.superview!=self)return;
    self.synchronizing=YES;
    @try {
        bridge.containerLayoutCount++;
        NSView *video=bridge.video;
        if(!NSEqualRects(video.frame,self.bounds)) {
            video.frame=self.bounds;bridge.videoFrameChangeCount++;
            // The root's redraw callback updates the original renderer's
            // backing-size cache; no playback state or second player changes.
            [bridge emit:SPPiPEventRedraw generation:self.generation value:0 reason:nil];
        }
    } @catch(NSException *exception) {
        bridge.lastFailure=SPExceptionDiagnostic(@"synchronize PiP video geometry",exception);
        [bridge emit:SPPiPEventFailed generation:self.generation value:0 reason:@"画中画视图布局失败"];
    } @finally {self.synchronizing=NO;}
}
- (void)setFrameSize:(NSSize)size { [super setFrameSize:size];[self synchronizeVideoFrame]; }
- (void)setBoundsSize:(NSSize)size { [super setBoundsSize:size];[self synchronizeVideoFrame]; }
- (void)layout { [super layout];[self synchronizeVideoFrame]; }
- (void)viewDidMoveToWindow { [super viewDidMoveToWindow];[self synchronizeVideoFrame]; }
@end
@interface SPContent : NSViewController
@property(nonatomic, weak) SPSystemPiPBridge *bridge;
@property(nonatomic) uint64_t generation;
@end
@implementation SPContent
- (void)viewDidAppear {
    [super viewDidAppear];
    if([self.view isKindOfClass:SPVideoContainer.class])[(SPVideoContainer *)self.view synchronizeVideoFrame];
    [self.bridge observe:self.generation];
}
- (void)viewDidLayout {
    [super viewDidLayout];
    if([self.view isKindOfClass:SPVideoContainer.class])[(SPVideoContainer *)self.view synchronizeVideoFrame];
    [self.bridge emit:SPPiPEventRedraw generation:self.generation value:0 reason:nil];
}
@end
@interface SPDelegate : NSObject
@property(nonatomic, weak) SPSystemPiPBridge *bridge;
@property(nonatomic) uint64_t generation;
@end
@implementation SPDelegate
- (void)pipWillClose:(id)pip {
    if(!NSThread.isMainThread) {
        __weak typeof(self) weak=self;
        dispatch_async(dispatch_get_main_queue(),^{[weak pipWillClose:nil];});return;
    }
    if(self.bridge.generation==self.generation) {
        self.bridge.exitRequested=YES;self.bridge.nativeWillClose=YES;
    }
    [self.bridge emit:SPPiPEventWillClose generation:self.generation value:0 reason:nil];
}
- (void)pipDidClose:(id)pip { [self.bridge closed:self.generation]; }
- (void)pipActionPlay:(id)pip {[self.bridge emit:SPPiPEventPlay generation:self.generation value:0 reason:nil];}
- (void)pipActionPause:(id)pip {[self.bridge emit:SPPiPEventPause generation:self.generation value:0 reason:nil];}
- (void)pipActionStop:(id)pip {[self.bridge emit:SPPiPEventStop generation:self.generation value:0 reason:nil];}
- (void)pipAction:(id)pip skipInterval:(NSTimeInterval)interval {[self.bridge emit:SPPiPEventSkip generation:self.generation value:interval reason:nil];}
@end

@implementation SPSystemPiPBridge
- (NSDictionary<NSString *,id> *)diagnostics {
    @try {if(self.video)self.lastGeometry=[self geometrySnapshot];}
    @catch(NSException *exception) {self.lastFailure=SPExceptionDiagnostic(@"read PiP geometry diagnostics",exception);}
    return @{@"operationStage":self.operationStage?:@"idle",@"presentationAttempts":@(self.presentationAttempts),
      @"generation":@(self.generation),@"controllerClass":self.controller?NSStringFromClass(self.controller.class):@"none",
      @"videoClass":self.video?NSStringFromClass(self.video.class):@"none",@"lastFailure":self.lastFailure?:@{},
      @"containerLayoutCount":@(self.containerLayoutCount),@"videoFrameChangeCount":@(self.videoFrameChangeCount),
      @"lastGeometry":self.lastGeometry?:@{},@"dismissalGeneration":@(self.dismissalGeneration),
      @"exitRequested":@(self.exitRequested),@"dismissIssued":@(self.dismissIssued),@"nativeWillClose":@(self.nativeWillClose),
      @"nativeCloseConfirmed":@(self.nativeCloseConfirmed),
      @"dismissRequestCount":@(self.dismissRequestCount),@"dismissAttemptCount":@(self.dismissAttemptCount),
      @"dismissSuppressedCount":@(self.dismissSuppressedCount),@"dismissDeferredCount":@(self.dismissDeferredCount),
      @"dismissExceptionCount":@(self.dismissExceptionCount)};
}
- (NSDictionary *)geometrySnapshot {
    NSView *container=self.content.view,*video=self.video;
    NSWindow *window=video.window;
    NSMutableArray *ancestors=[NSMutableArray array];
    for(NSView *view=container;view && ancestors.count<6;view=view.superview)[ancestors addObject:SPViewGeometry(view)];
    return @{@"generation":@(self.generation),@"video":SPViewGeometry(video),@"container":SPViewGeometry(container),
      @"ancestorChain":ancestors,@"windowClass":window?NSStringFromClass(window.class):@"none",
      @"windowVisible":@(window.isVisible),@"windowFrame":SPRectGeometry(window?window.frame:NSZeroRect),
      @"windowContentLayoutRect":SPRectGeometry(window?window.contentLayoutRect:NSZeroRect),
      @"windowContentView":SPViewGeometry(window.contentView),@"backingScaleFactor":@(window?window.backingScaleFactor:0)};
}
- (instancetype)init {
    self=[super init];if(!self)return nil;
    // Classes remain registered for process lifetime; deliberately never dlclose.
    self.framework=dlopen("/System/Library/PrivateFrameworks/PIP.framework/PIP",RTLD_NOW|RTLD_LOCAL);
    Class cls=self.framework?NSClassFromString(@"PIPViewController"):Nil;
    self.available=cls && [cls isSubclassOfClass:NSViewController.class]
      && SPMethod(cls,@"presentViewControllerAsPictureInPicture:",@encode(id))
      && SPMethod(cls,@"setDelegate:",@encode(id))
      && SPMethod(cls,@"setAspectRatio:",@encode(NSSize))
      && SPMethod(cls,@"dismissViewController:",@encode(id))
      && SPMethod(cls,@"setPlaying:",@encode(BOOL));
    self.controllerClass=cls;
    if(!self.available)self.unavailableReason=@"此系统的画中画接口或播放状态控制不可用";
    return self;
}
- (void)emit:(SPPiPEvent)event generation:(uint64_t)ticket value:(double)value reason:(NSString *)reason {
    if(!NSThread.isMainThread) {
        __weak typeof(self) weak=self;
        dispatch_async(dispatch_get_main_queue(),^{[weak emit:event generation:ticket value:value reason:reason];});return;
    }
    if(ticket!=self.generation)return;
    if(self.onEvent)self.onEvent(event,ticket,value,reason);
}
- (BOOL)presentView:(NSView *)view originWindow:(NSWindow *)window aspectRatio:(NSSize)ratio playing:(BOOL)playing generation:(uint64_t)ticket {
    self.presentationAttempts++;self.operationStage=@"present preflight";self.lastFailure=nil;
    NSString *rejection=!NSThread.isMainThread?@"main thread required":!self.available?@"system interface unavailable":self.controller?@"native controller still owned":!view?@"video view missing":!ticket?@"generation missing":nil;
    if(rejection) {self.lastFailure=@{@"stage":self.operationStage,@"reason":rejection};return NO;}
    self.generation=ticket;self.video=view;self.originWindow=window;self.started=NO;
    self.dismissalGeneration=ticket;self.exitRequested=NO;self.dismissIssued=NO;self.nativeWillClose=NO;self.nativeCloseConfirmed=NO;
    @try {
        // New controller/proxy per generation: old delegate callbacks cannot be
        // attributed to the new window after close/replacement/teardown.
        self.operationStage=@"create system controller";
        self.controller=[[self.controllerClass alloc] init];self.controller.title=@"SiliconPlayer";
        self.proxy=[SPDelegate new];self.proxy.bridge=self;self.proxy.generation=ticket;
        self.operationStage=@"set system delegate";
        SPObject(self.controller,@"setDelegate:",self.proxy);
        if(!(ratio.width>0 && ratio.height>0 && isfinite(ratio.width) && isfinite(ratio.height)))ratio=NSMakeSize(16,9);
        self.operationStage=@"set system aspect ratio";
        ((void (*)(id,SEL,NSSize))objc_msgSend)(self.controller,NSSelectorFromString(@"setAspectRatio:"),ratio);
        self.operationStage=@"create content container";
        self.content=[SPContent new];self.content.bridge=self;self.content.generation=ticket;
        SPVideoContainer *container=[[SPVideoContainer alloc] initWithFrame:NSMakeRect(0,0,view.frame.size.width,view.frame.size.height)];
        container.bridge=self;container.generation=ticket;
        container.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
        container.autoresizesSubviews=YES;container.translatesAutoresizingMaskIntoConstraints=YES;
        self.content.view=container;
        self.operationStage=@"attach existing video to content";
        view.frame=self.content.view.bounds;view.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
        view.translatesAutoresizingMaskIntoConstraints=YES;[self.content.view addSubview:view];
        self.operationStage=@"set initial playing state";[self updatePlaying:playing];
        if(self.generation!=ticket || !self.controller)return NO;
        self.operationStage=@"present installed system controller";
        SPObject(self.controller,@"presentViewControllerAsPictureInPicture:",self.content);
        __weak typeof(self) weak=self;
        self.timer=[NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer){[weak observe:ticket];}];
        self.operationStage=@"presentation request accepted";return YES;
    } @catch(NSException *e) {
        self.lastFailure=SPExceptionDiagnostic(self.operationStage,e);
        NSString *reason=[NSString stringWithFormat:@"画中画启动失败（%@）：%@ %@",self.operationStage,self.lastFailure[@"exceptionName"],self.lastFailure[@"reason"]];
        [self emit:SPPiPEventFailed generation:ticket value:0 reason:reason];
        (void)[self forceDetachGeneration:ticket];return NO;
    }
}
- (void)observe:(uint64_t)ticket {
    if(ticket!=self.generation || !self.content)return;
    @try {
        if([self.content.view isKindOfClass:SPVideoContainer.class])[(SPVideoContainer *)self.content.view synchronizeVideoFrame];
        self.lastGeometry=[self geometrySnapshot];
    } @catch(NSException *exception) {
        self.lastFailure=SPExceptionDiagnostic(@"observe PiP geometry",exception);
        [self emit:SPPiPEventFailed generation:ticket value:0 reason:@"画中画视图观察失败"];return;
    }
    NSWindow *window=self.video.window;
    Class panelClass=NSClassFromString(@"PIPPanel");
    if(window && panelClass && [window isKindOfClass:panelClass] && window!=self.originWindow && window.isVisible && self.video.superview==self.content.view) {
        self.observedPanel=window;
        [self recordObservedStart:ticket windowClass:NSStringFromClass(window.class)];
    }
}
- (void)recordObservedStart:(uint64_t)ticket windowClass:(NSString *)windowClass {
    if(!NSThread.isMainThread || ticket!=self.generation || !self.controller || self.started)return;
    self.started=YES;
    [self emit:SPPiPEventStarted generation:ticket value:0 reason:windowClass];
    // A Started callback may synchronously request exit or even close this
    // generation. The idempotent native gate owns the deferred request.
    if(ticket==self.generation && self.exitRequested)[self dismissGeneration:ticket];
}
- (void)dismissGeneration:(uint64_t)ticket {
    if(!NSThread.isMainThread || ticket!=self.generation || !self.controller)return;
    self.dismissRequestCount++;self.exitRequested=YES;
    if(self.nativeWillClose || self.dismissIssued) {self.dismissSuppressedCount++;return;}
    // The installed controller can still be moving the content into its panel.
    // Early Stop/replacement/quit owns the attachment while waiting for actual
    // visible-panel observation; it must not dismiss the same child twice.
    if(!self.started) {self.dismissDeferredCount++;return;}
    self.dismissIssued=YES;self.dismissAttemptCount++;
    self.operationStage=@"dismiss installed system controller";
    @try { [self.controller dismissViewController:self.content]; }
    @catch(NSException *exception) {
        self.dismissExceptionCount++;self.lastFailure=SPExceptionDiagnostic(self.operationStage,exception);
        NSString *reason=[NSString stringWithFormat:@"画中画退出失败（%@）：%@ %@",self.operationStage,
          self.lastFailure[@"exceptionName"],self.lastFailure[@"reason"]];
        [self emit:SPPiPEventFailed generation:ticket value:0 reason:reason];
    }
}
- (void)updatePlaying:(BOOL)playing {
    if(!NSThread.isMainThread || !self.controller)return;
    if(SPMethod(self.controller.class,@"setPlaying:",@encode(BOOL))) {
        @try {((void (*)(id,SEL,BOOL))objc_msgSend)(self.controller,NSSelectorFromString(@"setPlaying:"),playing);}
        @catch(NSException *e) {
            self.lastFailure=SPExceptionDiagnostic(self.operationStage?:@"update playing state",e);
            [self emit:SPPiPEventFailed generation:self.generation value:0 reason:[NSString stringWithFormat:@"画中画状态更新失败：%@ %@",self.lastFailure[@"exceptionName"],self.lastFailure[@"reason"]]];
        }
    }
}
- (void)closed:(uint64_t)ticket {
    if(!NSThread.isMainThread) {__weak typeof(self) weak=self;dispatch_async(dispatch_get_main_queue(),^{[weak closed:ticket];});return;}
    if(ticket!=self.generation || !self.controller)return;
    @try {
        [self.timer invalidate];self.timer=nil;
        SPObject(self.controller,@"setDelegate:",nil);
        SPContent *oldContent=self.content;NSView *oldVideo=self.video;
        void (^callback)(SPPiPEvent,uint64_t,double,NSString *)=self.onEvent;
        self.nativeCloseConfirmed=YES;
        self.content=nil;self.controller=nil;self.proxy=nil;self.video=nil;self.observedPanel=nil;self.generation=0;
        // Callback restores under the attachment's exception/move guards. New
        // reentrant presentation is allowed; no old ticket is cleared afterwards.
        if(callback)callback(SPPiPEventClosed,ticket,0,nil);
        if(oldVideo.superview==oldContent.view)[oldVideo removeFromSuperview];
    } @catch(NSException *e) {[self emit:SPPiPEventFailed generation:ticket value:0 reason:@"画中画关闭恢复失败"];} 
}
- (BOOL)forceDetachGeneration:(uint64_t)ticket {
    if(!NSThread.isMainThread)return NO;
    if(self.generation && ticket!=self.generation)return NO;
    if(!self.controller) {
        @try {
            if(self.content && self.video.superview==self.content.view)[self.video removeFromSuperview];
            [self.timer invalidate];self.timer=nil;self.content=nil;self.proxy=nil;self.video=nil;self.generation=0;
            return YES;
        } @catch(NSException *e) {return NO;}
    }
    NSView *video=self.video;NSView *container=self.content.view;
    NSWindow *panel=self.observedPanel;NSWindow *origin=self.originWindow;
    Class panelClass=NSClassFromString(@"PIPPanel");
    BOOL ownedPanel=panel && panelClass && [panel isKindOfClass:panelClass]
      && panel!=origin && panel==container.window;
    @try {
        [self.timer invalidate];self.timer=nil;
        SPObject(self.controller,@"setDelegate:",nil);
        if(video.superview==container)[video removeFromSuperview];self.content.view=[NSView new];
    } @catch(NSException *e) { /* Detachment is checked independently below. */ }
    // A failed dismiss must not prevent hiding/closing the positively owned
    // panel after detachment. Never apply these operations to an unknown window.
    @try {[self.controller dismissViewController:self.content];}@catch(NSException *e){}
    if(ownedPanel) {@try {[panel orderOut:nil];[panel close];}@catch(NSException *e){}}
    BOOL detached=video.superview!=container && (!panel || video.window!=panel);
    if(detached) {self.generation=0;self.content=nil;self.controller=nil;self.proxy=nil;self.video=nil;self.observedPanel=nil;}
    return detached;
}
@end

@interface SPSystemPiPAttachment ()
@property(nonatomic, readwrite) NSView *videoView;
@property(nonatomic, readwrite) NSView *host;
@property(nonatomic, readwrite, getter=isRestored) BOOL restored;
@property(nonatomic, strong) NSView *placeholder;
@property(nonatomic, strong) NSArray<NSLayoutConstraint *> *originalConstraints;
@property(nonatomic, strong) NSArray<NSLayoutConstraint *> *placeholderConstraints;
@property(nonatomic) NSRect frame;
@property(nonatomic) NSAutoresizingMaskOptions mask;
@property(nonatomic) BOOL translates;
@property(nonatomic) BOOL filledHost;
@property(nonatomic, weak) NSWindow *window;
@property(nonatomic, weak) NSResponder *responder;
@property(nonatomic, copy) NSString *operationStage;
@property(nonatomic, strong) NSDictionary *lastFailure;
@property(nonatomic, strong) NSArray<NSString *> *capturedConstraintClasses;
@property(nonatomic) NSUInteger generatedConstraintCount;
@end
@implementation SPSystemPiPAttachment
- (NSDictionary<NSString *,id> *)diagnostics {
    return @{@"operationStage":self.operationStage?:@"idle",@"lastFailure":self.lastFailure?:@{},
      @"viewClass":NSStringFromClass(self.videoView.class),@"hostClass":NSStringFromClass(self.host.class),
      @"restored":@(self.restored),@"viewInOriginalHost":@(self.videoView.superview==self.host),
      @"originalConstraintCount":@(self.originalConstraints.count),@"generatedAutoresizingConstraintCount":@(self.generatedConstraintCount),
      @"capturedConstraintClasses":self.capturedConstraintClasses?:@[],@"originalTranslatesAutoresizingMask":@(self.translates)};
}
- (instancetype)initWithVideoView:(NSView *)view host:(NSView *)host {
    if(!NSThread.isMainThread || view==host || view.superview!=host)return nil;
    self=[super init];if(!self)return nil;
    @try {
        self.videoView=view;self.host=host;self.frame=view.frame;self.mask=view.autoresizingMask;
        self.translates=view.translatesAutoresizingMaskIntoConstraints;self.filledHost=NSEqualRects(view.frame,host.bounds);
        self.window=view.window;self.responder=view.window.firstResponder;self.restored=YES;
        NSMutableArray *constraints=[NSMutableArray array];NSMutableArray *classes=[NSMutableArray array];
        for(NSView *owner=view;owner;owner=owner.superview)
            for(NSLayoutConstraint *c in owner.constraints)
                if(c.isActive && (c.firstItem==view || c.secondItem==view)) {
                    NSString *name=NSStringFromClass(c.class);if(classes.count<32)[classes addObject:name];
                    // AppKit regenerates mask constraints from the separately
                    // saved frame/mask. Never clone them as explicit user constraints.
                    if([name containsString:@"AutoresizingMaskLayoutConstraint"]) {self.generatedConstraintCount++;continue;}
                    [constraints addObject:c];
                }
        self.originalConstraints=constraints;
        self.capturedConstraintClasses=classes;self.operationStage=@"attachment captured";
    } @catch(NSException *e){return nil;}
    return self;
}
- (BOOL)prepareForPiP {
    self.operationStage=@"prepare preflight";self.lastFailure=nil;
    NSString *rejection=!NSThread.isMainThread?@"main thread required":!self.restored?@"attachment not restored":self.videoView.superview!=self.host?@"video left original host":nil;
    if(rejection) {self.lastFailure=@{@"stage":self.operationStage,@"reason":rejection};return NO;}
    @try {
        self.operationStage=@"create placeholder";
        NSView *view=self.videoView;self.placeholder=[[NSView alloc] initWithFrame:self.frame];
        self.placeholder.autoresizingMask=self.mask;self.placeholder.translatesAutoresizingMaskIntoConstraints=self.translates;
        self.operationStage=@"attach placeholder to original host";
        [self.host addSubview:self.placeholder positioned:NSWindowAbove relativeTo:view];
        self.operationStage=@"copy explicit attachment constraints";
        NSMutableArray *copies=[NSMutableArray array];
        for(NSLayoutConstraint *c in self.originalConstraints) {
            id first=c.firstItem==view?self.placeholder:c.firstItem;
            id second=c.secondItem==view?self.placeholder:c.secondItem;
            NSLayoutConstraint *copy=[NSLayoutConstraint constraintWithItem:first attribute:c.firstAttribute
              relatedBy:c.relation toItem:second attribute:c.secondAttribute multiplier:c.multiplier constant:c.constant];
            copy.priority=c.priority;[copies addObject:copy];
        }
        self.placeholderConstraints=copies;self.operationStage=@"deactivate original explicit constraints";
        [NSLayoutConstraint deactivateConstraints:self.originalConstraints];
        self.operationStage=@"activate placeholder constraints";[NSLayoutConstraint activateConstraints:copies];
        self.operationStage=@"detach existing video from original host";[view removeFromSuperview];
        self.restored=NO;self.operationStage=@"attachment prepared";return YES;
    } @catch(NSException *e){self.lastFailure=SPExceptionDiagnostic(self.operationStage,e);self.restored=NO;(void)[self restore];return NO;}
}
- (BOOL)restore {
    if(!NSThread.isMainThread)return NO;
    if(self.restored && self.videoView.superview==self.host)return YES;
    @try {
        NSView *view=self.videoView;[view removeFromSuperview];
        view.translatesAutoresizingMaskIntoConstraints=self.translates;view.autoresizingMask=self.mask;
        view.frame=self.filledHost?self.host.bounds:(self.placeholder?self.placeholder.frame:self.frame);
        [self.host addSubview:view positioned:NSWindowBelow relativeTo:self.placeholder.superview==self.host?self.placeholder:nil];
        [NSLayoutConstraint deactivateConstraints:self.placeholderConstraints?:@[]];[self.placeholder removeFromSuperview];
        [NSLayoutConstraint activateConstraints:self.originalConstraints];[self.host layoutSubtreeIfNeeded];
        if(self.window.isKeyWindow && self.responder)[self.window makeFirstResponder:self.responder];
        self.placeholder=nil;self.restored=view.superview==self.host;return self.restored;
    } @catch(NSException *e){if(!self.lastFailure)self.lastFailure=SPExceptionDiagnostic(@"restore attachment",e);return NO;}
}
@end
