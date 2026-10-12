#import "SPFTPTransfer.h"
#include <curl/curl.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <pthread.h>
#include <errno.h>
#include <stdint.h>

static pthread_once_t SPGlobalOnce = PTHREAD_ONCE_INIT;
static CURLcode SPGlobalResult = CURLE_FAILED_INIT;
static void SPInitializeCurl(void) { SPGlobalResult = curl_global_init(CURL_GLOBAL_DEFAULT); }

@interface SPFTPTransfer () {
    NSLock *_lock;
    CURL *_retiredEasy; CURLM *_retiredMulti;
    NSURL *_address, *_outputFolder;
    NSString *_username, *_password, *_outputName;
    BOOL _requireTLS, _listingMode, _cancelled, _executing, _executed;
    BOOL _nativeReleased, _cleanupConfirmed, _removeOutput, _unlinkPending, _published;
    BOOL _fileCloseAttempted, _directoryCloseAttempted;
    int _fileFD, _directoryFD, _caFileFD;
    struct stat _caFileIdentity;
    BOOL _caFileCreated, _caFileCloseAttempted, _caUnlinkPending;
    NSData *_certificateAuthorityPEM;
    struct stat _fileIdentity, _directoryIdentity;
    int64_t _maximumBytes, _received, _expected;
    NSInteger _curlCode, _responseCode;
    NSString *_stage;
    NSMutableData *_listing;
}
- (BOOL)isCancelled;
- (void)setStage:(NSString *)value;
- (size_t)consume:(const void *)bytes length:(size_t)length;
- (void)setExpected:(int64_t)value;
- (BOOL)releaseFD:(int *)fd identity:(struct stat)identity attempted:(BOOL *)attempted;
@end

static size_t SPWrite(char *bytes, size_t size, size_t count, void *context) {
    if (size && count > SIZE_MAX / size) return 0;
    return [(__bridge SPFTPTransfer *)context consume:bytes length:size * count];
}
static int SPProgress(void *context, curl_off_t total, curl_off_t now, curl_off_t upTotal, curl_off_t upNow) {
    (void)now; (void)upTotal; (void)upNow;
    SPFTPTransfer *task = (__bridge SPFTPTransfer *)context;
    [task setExpected:(int64_t)total];
    return [task isCancelled] ? 1 : 0;
}

@implementation SPFTPTransfer
- (instancetype)initWithAddress:(NSURL *)address username:(NSString *)username password:(NSString *)password
                    requireTLS:(BOOL)requireTLS listingMode:(BOOL)listingMode outputFolder:(NSURL *)outputFolder
                    outputName:(NSString *)outputName maximumBytes:(int64_t)maximumBytes {
    return [self initWithAddress:address username:username password:password requireTLS:requireTLS
        listingMode:listingMode outputFolder:outputFolder outputName:outputName maximumBytes:maximumBytes
        certificateAuthorityPEM:nil];
}
- (instancetype)initWithAddress:(NSURL *)address username:(NSString *)username password:(NSString *)password
                    requireTLS:(BOOL)requireTLS listingMode:(BOOL)listingMode outputFolder:(NSURL *)outputFolder
                    outputName:(NSString *)outputName maximumBytes:(int64_t)maximumBytes
       certificateAuthorityPEM:(NSData *)certificateAuthorityPEM {
    if ((self = [super init])) {
        _lock = [NSLock new]; _address = [address copy]; _username = [username copy]; _password = [password copy];
        _requireTLS = requireTLS; _listingMode = listingMode; _outputFolder = [outputFolder copy]; _outputName = [outputName copy];
        _maximumBytes = maximumBytes; _fileFD = -1; _directoryFD = -1; _caFileFD = -1; _expected = -1;
        _certificateAuthorityPEM = [certificateAuthorityPEM copy];
        _curlCode = CURLE_FAILED_INIT; [self setStage:@"created"]; _listing = [NSMutableData data];
    }
    return self;
}
+ (NSDictionary<NSString *,id> *)capabilities {
    pthread_once(&SPGlobalOnce, SPInitializeCurl);
    curl_version_info_data *v = curl_version_info(CURLVERSION_NOW);
    NSMutableArray<NSString *> *protocols = [NSMutableArray array];
    if (v && v->protocols) for (const char *const *p = v->protocols; *p; ++p) {
        NSString *name = [NSString stringWithUTF8String:*p]; if (name) [protocols addObject:name];
    }
    return @{@"initialized": @((BOOL)(SPGlobalResult == CURLE_OK)),
             @"headerVersion": [NSString stringWithUTF8String:LIBCURL_VERSION],
             @"runtimeVersion": v ? [NSString stringWithUTF8String:v->version] : @"unavailable",
             @"tlsBackend": v && v->ssl_version ? [NSString stringWithUTF8String:v->ssl_version] : @"unavailable",
             @"versionNumber": @(v ? v->version_num : 0), @"protocols": [protocols copy],
             @"asynchronousDNS": @((BOOL)(v && (v->features & CURL_VERSION_ASYNCHDNS))),
             @"threadSafeInitialization": @((BOOL)(v && (v->features & CURL_VERSION_THREADSAFE))),
             @"tls": @((BOOL)(v && (v->features & CURL_VERSION_SSL)))};
}
- (void)setStage:(NSString *)value { [_lock lock]; _stage = [value copy]; [_lock unlock]; }
- (void)cancel { [_lock lock]; _cancelled = YES; [_lock unlock]; }
- (BOOL)isCancelled { [_lock lock]; BOOL v = _cancelled; [_lock unlock]; return v; }
- (void)setExpected:(int64_t)value { [_lock lock]; _expected = value > 0 ? value : -1; [_lock unlock]; }
- (NSDictionary<NSString *,id> *)snapshot {
    [_lock lock];
    NSDictionary *r = @{@"executing": @((BOOL)_executing), @"executed": @((BOOL)_executed),
        @"cancelled": @((BOOL)_cancelled), @"released": @((BOOL)(_executed && _nativeReleased && _cleanupConfirmed)),
        @"published": @((BOOL)_published), @"received": @(_received), @"expected": @(_expected),
        @"curlCode": @(_curlCode), @"responseCode": @(_responseCode), @"stage": _stage,
        @"trustMode": _certificateAuthorityPEM ? @"explicit-connection-ca" : @"system-default",
        @"requiredVerifyPeer": @YES, @"requiredVerifyHost": @2};
    [_lock unlock]; return r;
}
- (size_t)consume:(const void *)bytes length:(size_t)length {
    if ([self isCancelled]) return 0;
    [_lock lock];
    BOOL tooLarge = length > (uint64_t)INT64_MAX || _received > _maximumBytes - (int64_t)length;
    [_lock unlock];
    if (tooLarge) { [self setStage:@"size-bound"]; return 0; }
    if (_listingMode) [_listing appendBytes:bytes length:length];
    else {
        size_t offset = 0;
        while (offset < length) {
            if ([self isCancelled]) return 0;
            ssize_t n = write(_fileFD, (const char *)bytes + offset, length - offset);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) { [self setStage:@"disk-write"]; return 0; }
            offset += (size_t)n;
        }
    }
    [_lock lock]; _received += (int64_t)length; [_lock unlock]; return length;
}
/// A failed close makes this numeric descriptor ambiguous even if dev/ino later
/// happen to match. A retry accepts only EBADF; it never closes a reused FD.
- (BOOL)releaseFD:(int *)fd identity:(struct stat)identity attempted:(BOOL *)attempted {
    if (*fd < 0) return YES;
    struct stat current;
    if (fstat(*fd, &current) != 0) {
        if (errno == EBADF) { *fd = -1; return YES; }
        return NO;
    }
    if (*attempted || current.st_dev != identity.st_dev || current.st_ino != identity.st_ino) return NO;
    *attempted = YES;
    int value = *fd;
    if (close(value) == 0) { *fd = -1; return YES; }
    if (fcntl(value, F_GETFD) < 0 && errno == EBADF) { *fd = -1; return YES; }
    return NO;
}
- (BOOL)retryCleanup {
    [_lock lock];
    if (!_executed || _executing) { [_lock unlock]; return NO; }
    if (!_nativeReleased) {
        if (_retiredMulti) {
            if (_retiredEasy) curl_multi_remove_handle(_retiredMulti, _retiredEasy);
            if (curl_multi_cleanup(_retiredMulti) != CURLM_OK) { [_lock unlock]; return NO; }
            _retiredMulti = NULL;
        }
        if (_retiredEasy) { curl_easy_cleanup(_retiredEasy); _retiredEasy = NULL; }
        _nativeReleased = YES;
    }
    BOOL fileClosed = [self releaseFD:&_fileFD identity:_fileIdentity attempted:&_fileCloseAttempted];
    if (fileClosed && _unlinkPending && _directoryFD >= 0) {
        // openat/fstatat bind cleanup to our exact regular file, not just a name.
        struct stat s;
        if (fstatat(_directoryFD, _outputName.fileSystemRepresentation, &s, AT_SYMLINK_NOFOLLOW) != 0) {
            if (errno == ENOENT) _unlinkPending = NO;
        } else if (S_ISREG(s.st_mode) && s.st_dev == _fileIdentity.st_dev && s.st_ino == _fileIdentity.st_ino) {
            if (unlinkat(_directoryFD, _outputName.fileSystemRepresentation, 0) == 0) _unlinkPending = NO;
        }
    }
    BOOL caClosed = [self releaseFD:&_caFileFD identity:_caFileIdentity attempted:&_caFileCloseAttempted];
    if (caClosed && _caUnlinkPending && _directoryFD >= 0) {
        struct stat ca;
        if (fstatat(_directoryFD, ".connection-ca.pem", &ca, AT_SYMLINK_NOFOLLOW) != 0) {
            if (errno == ENOENT) _caUnlinkPending = NO;
        } else if (S_ISREG(ca.st_mode) && ca.st_dev == _caFileIdentity.st_dev && ca.st_ino == _caFileIdentity.st_ino) {
            if (unlinkat(_directoryFD, ".connection-ca.pem", 0) == 0) _caUnlinkPending = NO;
        }
    }
    BOOL dirClosed = !_unlinkPending && !_caUnlinkPending &&
        [self releaseFD:&_directoryFD identity:_directoryIdentity attempted:&_directoryCloseAttempted];
    BOOL done = fileClosed && caClosed && dirClosed && !_unlinkPending && !_caUnlinkPending;
    _cleanupConfirmed = done; // only this lock-held actual cleanup path publishes it
    [_lock unlock]; return done;
}
- (NSDictionary<NSString *,id> *)execute {
    [_lock lock];
    if (_executed || _executing) { [_lock unlock]; return [self snapshot]; }
    _executing = YES; [_lock unlock];
    CURL *easy = NULL; CURLM *multi = NULL; BOOL attached = NO;
    CURLcode code = CURLE_FAILED_INIT; long reply = 0; curl_off_t expected = -1;
    @try {
        NSDictionary *caps = [SPFTPTransfer capabilities];
        NSString *scheme = _address.scheme.lowercaseString;
        if (![caps[@"initialized"] boolValue] || [caps[@"versionNumber"] unsignedLongValue] < 0x075500 ||
            ![caps[@"asynchronousDNS"] boolValue] || ![caps[@"threadSafeInitialization"] boolValue] ||
            ![caps[@"protocols"] containsObject:scheme] ||
            !([scheme isEqualToString:@"ftp"] || [scheme isEqualToString:@"ftps"]) ||
            _address.user != nil || _address.password != nil || _address.query != nil || _address.fragment != nil ||
            !_address.host.length || _maximumBytes <= 0 ||
            (_requireTLS && ![caps[@"tls"] boolValue])) { [self setStage:@"capability-or-address"]; goto cleanup; }
        if ([self isCancelled]) { code = CURLE_ABORTED_BY_CALLBACK; goto cleanup; }
        if (!_listingMode) {
            if (!_outputFolder.isFileURL || !_outputName.length || [_outputName containsString:@"/"] ||
                [_outputName isEqualToString:@"."] || [_outputName isEqualToString:@".."]) { [self setStage:@"output-address"]; goto cleanup; }
            _directoryFD = open(_outputFolder.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
            if (_directoryFD < 0 || fstat(_directoryFD, &_directoryIdentity) != 0 || !S_ISDIR(_directoryIdentity.st_mode)) { [self setStage:@"output-directory"]; goto cleanup; }
            _fileFD = openat(_directoryFD, _outputName.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0600);
            if (_fileFD < 0 || fstat(_fileFD, &_fileIdentity) != 0 || !S_ISREG(_fileIdentity.st_mode)) { [self setStage:@"output-exclusive-file"]; goto cleanup; }
            _removeOutput = YES;
        }
        if (_certificateAuthorityPEM) {
            // An explicitly scoped CAINFO file is used here. This does not claim
            // anything about CAINFO_BLOB support in the actual Apple binary.
            if (!_requireTLS || !_certificateAuthorityPEM.length || _certificateAuthorityPEM.length > 1048576 ||
                !_outputFolder.isFileURL) { [self setStage:@"ca-input"]; goto cleanup; }
            if (_directoryFD < 0) {
                _directoryFD = open(_outputFolder.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
                if (_directoryFD < 0 || fstat(_directoryFD, &_directoryIdentity) != 0 || !S_ISDIR(_directoryIdentity.st_mode)) {
                    [self setStage:@"ca-directory"]; goto cleanup;
                }
            }
            if (_directoryIdentity.st_uid != geteuid() || (_directoryIdentity.st_mode & 0777) != 0700) {
                [self setStage:@"ca-directory-permissions"]; goto cleanup;
            }
            _caFileFD = openat(_directoryFD, ".connection-ca.pem", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0600);
            if (_caFileFD < 0) { [self setStage:@"ca-exclusive-file"]; goto cleanup; }
            _caFileCreated = YES;
            if (fstat(_caFileFD, &_caFileIdentity) != 0 || !S_ISREG(_caFileIdentity.st_mode) ||
                (_caFileIdentity.st_mode & 0777) != 0600) { [self setStage:@"ca-file-identity"]; goto cleanup; }
            size_t offset = 0;
            while (offset < _certificateAuthorityPEM.length) {
                if ([self isCancelled]) { code = CURLE_ABORTED_BY_CALLBACK; goto cleanup; }
                ssize_t n = write(_caFileFD, (const char *)_certificateAuthorityPEM.bytes + offset, _certificateAuthorityPEM.length - offset);
                if (n < 0 && errno == EINTR) continue;
                if (n <= 0) { code = CURLE_WRITE_ERROR; [self setStage:@"ca-write"]; goto cleanup; }
                offset += (size_t)n;
            }
            struct stat namedCA;
            if (fsync(_caFileFD) != 0 || fstatat(_directoryFD, ".connection-ca.pem", &namedCA, AT_SYMLINK_NOFOLLOW) != 0 ||
                !S_ISREG(namedCA.st_mode) || namedCA.st_dev != _caFileIdentity.st_dev || namedCA.st_ino != _caFileIdentity.st_ino) {
                code = CURLE_WRITE_ERROR; [self setStage:@"ca-sync-identity"]; goto cleanup;
            }
        }
        easy = curl_easy_init(); multi = curl_multi_init();
        if (!easy || !multi) { [self setStage:@"native-init"]; goto cleanup; }
#define SPSET(opt, value) do { code = curl_easy_setopt(easy, opt, value); if (code != CURLE_OK) { [self setStage:@"option-rejected"]; goto cleanup; } } while (0)
        SPSET(CURLOPT_URL, _address.absoluteString.UTF8String);
        SPSET(CURLOPT_USERNAME, _username.UTF8String);
        SPSET(CURLOPT_PASSWORD, _password.UTF8String);
        SPSET(CURLOPT_PROTOCOLS_STR, "ftp,ftps");
        SPSET(CURLOPT_REDIR_PROTOCOLS_STR, "ftp,ftps");
        SPSET(CURLOPT_FOLLOWLOCATION, 0L);
        SPSET(CURLOPT_PROXY, "");
        SPSET(CURLOPT_NETRC, (long)CURL_NETRC_IGNORED);
        SPSET(CURLOPT_NOSIGNAL, 1L);
        SPSET(CURLOPT_CONNECTTIMEOUT_MS, 10000L);
        SPSET(CURLOPT_TIMEOUT_MS, _listingMode ? 25000L : 86400000L);
        SPSET(CURLOPT_LOW_SPEED_LIMIT, 1L);
        SPSET(CURLOPT_LOW_SPEED_TIME, 25L);
        SPSET(CURLOPT_FTP_USE_EPSV, 1L);
        SPSET(CURLOPT_FTP_SKIP_PASV_IP, 1L);
        SPSET(CURLOPT_FTP_FILEMETHOD, (long)CURLFTPMETHOD_SINGLECWD);
        SPSET(CURLOPT_USE_SSL, (long)(_requireTLS ? CURLUSESSL_ALL : CURLUSESSL_NONE));
        SPSET(CURLOPT_SSL_VERIFYPEER, 1L); SPSET(CURLOPT_SSL_VERIFYHOST, 2L);
        if (_requireTLS) SPSET(CURLOPT_SSLVERSION, (long)CURL_SSLVERSION_TLSv1_2);
        if (_certificateAuthorityPEM) {
            SPSET(CURLOPT_CAINFO, [_outputFolder URLByAppendingPathComponent:@".connection-ca.pem"].fileSystemRepresentation);
        }
        SPSET(CURLOPT_WRITEFUNCTION, SPWrite); SPSET(CURLOPT_WRITEDATA, (__bridge void *)self);
        SPSET(CURLOPT_NOPROGRESS, 0L); SPSET(CURLOPT_XFERINFOFUNCTION, SPProgress);
        SPSET(CURLOPT_XFERINFODATA, (__bridge void *)self);
        SPSET(CURLOPT_MAXFILESIZE_LARGE, (curl_off_t)_maximumBytes);
        if (_listingMode) SPSET(CURLOPT_CUSTOMREQUEST, "MLSD");
#undef SPSET
        if (curl_multi_add_handle(multi, easy) != CURLM_OK) { code = CURLE_FAILED_INIT; [self setStage:@"multi-add"]; goto cleanup; }
        attached = YES; [self setStage:@"transferring"];
        for (;;) {
            if ([self isCancelled]) { code = CURLE_ABORTED_BY_CALLBACK; break; }
            int running = 0;
            if (curl_multi_perform(multi, &running) != CURLM_OK) { code = CURLE_RECV_ERROR; [self setStage:@"multi-perform"]; break; }
            int count = 0; CURLMsg *message; BOOL done = NO;
            while ((message = curl_multi_info_read(multi, &count))) if (message->msg == CURLMSG_DONE && message->easy_handle == easy) {
                code = message->data.result; done = YES;
            }
            if (done) break;
            if (!running) { code = CURLE_RECV_ERROR; [self setStage:@"missing-completion"]; break; }
            if (curl_multi_poll(multi, NULL, 0, 100, NULL) != CURLM_OK) { code = CURLE_RECV_ERROR; [self setStage:@"multi-poll"]; break; }
        }
        curl_easy_getinfo(easy, CURLINFO_RESPONSE_CODE, &reply);
        curl_easy_getinfo(easy, CURLINFO_CONTENT_LENGTH_DOWNLOAD_T, &expected);
        if ([self isCancelled]) code = CURLE_ABORTED_BY_CALLBACK;
        if (code == CURLE_OK && (!_listingMode && (_received <= 0 || (expected >= 0 && expected != _received)))) { code = CURLE_PARTIAL_FILE; [self setStage:@"size-mismatch"]; }
        if (code == CURLE_OK && _certificateAuthorityPEM) {
            struct stat heldCA, namedCA;
            if (fstat(_caFileFD, &heldCA) != 0 || fstatat(_directoryFD, ".connection-ca.pem", &namedCA, AT_SYMLINK_NOFOLLOW) != 0 ||
                !S_ISREG(namedCA.st_mode) || heldCA.st_dev != _caFileIdentity.st_dev || heldCA.st_ino != _caFileIdentity.st_ino ||
                namedCA.st_dev != heldCA.st_dev || namedCA.st_ino != heldCA.st_ino ||
                heldCA.st_size != (off_t)_certificateAuthorityPEM.length) { code = CURLE_SSL_CACERT_BADFILE; [self setStage:@"ca-changed"]; }
            if (code == CURLE_OK) {
                NSMutableData *actualCA = [NSMutableData dataWithLength:_certificateAuthorityPEM.length];
                size_t offset = 0;
                while (offset < actualCA.length) {
                    ssize_t n = pread(_caFileFD, (char *)actualCA.mutableBytes + offset, actualCA.length - offset, (off_t)offset);
                    if (n < 0 && errno == EINTR) continue;
                    if (n <= 0) break;
                    offset += (size_t)n;
                }
                if (offset != actualCA.length || ![actualCA isEqualToData:_certificateAuthorityPEM]) {
                    code = CURLE_SSL_CACERT_BADFILE; [self setStage:@"ca-changed"]; }
            }
        }
        if (code == CURLE_OK && _fileFD >= 0 && fsync(_fileFD) != 0) { code = CURLE_WRITE_ERROR; [self setStage:@"disk-sync"]; }
cleanup:
        if (attached && curl_multi_remove_handle(multi, easy) != CURLM_OK) { [self setStage:@"native-remove-failure"]; code = CURLE_FAILED_INIT; }
        CURLMcode cleanupCode = multi ? curl_multi_cleanup(multi) : CURLM_OK;
        if (cleanupCode == CURLM_OK) {
            multi = NULL; if (easy) { curl_easy_cleanup(easy); easy = NULL; }
        } else { [self setStage:@"native-cleanup-failure"]; code = CURLE_FAILED_INIT; }
    } @catch (NSException *exception) {
        (void)exception; [self setStage:@"native-exception"]; code = CURLE_FAILED_INIT;
        if (attached && multi && easy) curl_multi_remove_handle(multi, easy);
        CURLMcode cleanupCode = multi ? curl_multi_cleanup(multi) : CURLM_OK;
        if (cleanupCode == CURLM_OK) {
            multi = NULL; if (easy) { curl_easy_cleanup(easy); easy = NULL; }
        }
    }
    [_lock lock];
    _retiredEasy = easy; _retiredMulti = multi; _nativeReleased = easy == NULL && multi == NULL;
    _curlCode = code; _responseCode = reply; _expected = expected;
    _published = code == CURLE_OK && !_cancelled;
    _unlinkPending = _removeOutput && !_published;
    _caUnlinkPending = _caFileCreated;
    _username = @""; _password = @""; _executing = NO; _executed = YES;
    if ([ _stage isEqualToString:@"transferring"]) _stage = _published ? @"complete" : @"transfer-failed";
    [_lock unlock];
    [self retryCleanup];
    NSMutableDictionary *r = [[self snapshot] mutableCopy];
    if (_listingMode && _published) r[@"listing"] = [_listing copy];
    [_listing setLength:0];
    return r;
}
@end
