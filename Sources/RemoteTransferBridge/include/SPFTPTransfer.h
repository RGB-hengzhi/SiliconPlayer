#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// This object owns one isolated libcurl easy/multi pair. execute is called
/// once on a serial worker. cancel/snapshot are lock-safe on any thread.
/// No credentials or server response text are included in diagnostics.
@interface SPFTPTransfer : NSObject
- (instancetype)initWithAddress:(NSURL *)address
                      username:(NSString *)username
                      password:(NSString *)password
                    requireTLS:(BOOL)requireTLS
                   listingMode:(BOOL)listingMode
                  outputFolder:(nullable NSURL *)outputFolder
                    outputName:(nullable NSString *)outputName
                  maximumBytes:(int64_t)maximumBytes NS_SWIFT_NAME(init(address:username:password:requireTLS:listingMode:outputFolder:outputName:maximumBytes:));
/// An optional bounded PEM bundle is copied into an exclusive file in the
/// supplied private outputFolder for this one transfer. nil keeps default trust.
/// Verify-peer/verify-host remain strict; unsupported CA options fail closed.
- (instancetype)initWithAddress:(NSURL *)address
                      username:(NSString *)username
                      password:(NSString *)password
                    requireTLS:(BOOL)requireTLS
                   listingMode:(BOOL)listingMode
                  outputFolder:(nullable NSURL *)outputFolder
                    outputName:(nullable NSString *)outputName
                  maximumBytes:(int64_t)maximumBytes
       certificateAuthorityPEM:(nullable NSData *)certificateAuthorityPEM NS_SWIFT_NAME(init(address:username:password:requireTLS:listingMode:outputFolder:outputName:maximumBytes:certificateAuthorityPEM:));
- (void)cancel;
/// Immutable, bounded property-list result. execute only returns after native
/// cleanup was attempted. released must be true before dropping this owner.
- (NSDictionary<NSString *, id> *)execute;
- (NSDictionary<NSString *, id> *)snapshot;
- (BOOL)retryCleanup;
+ (NSDictionary<NSString *, id> *)capabilities;
@end
NS_ASSUME_NONNULL_END
