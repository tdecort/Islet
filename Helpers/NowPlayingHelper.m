// Now Playing bridge for Islet.
//
// macOS 15.4+ only answers MediaRemote (the system Now Playing service behind Control
// Center) for Apple's own binaries. /usr/bin/perl is one of them, so Islet runs
//   /usr/bin/perl -e '<loader>' IsletNowPlaying.dylib stream
// and this library, loaded into perl, streams the system's Now Playing state as one JSON
// object per line on stdout, and reads commands from stdin: toggle, next, prev, seek <s>.
// It exits as soon as stdin closes, so it never outlives Islet.

#import <Foundation/Foundation.h>
#include <dlfcn.h>

typedef void (*RegisterFn)(dispatch_queue_t);
typedef void (*GetInfoFn)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*GetClientFn)(dispatch_queue_t, void (^)(id));
typedef CFStringRef (*ClientBundleFn)(id);
typedef Boolean (*SendCommandFn)(int, CFDictionaryRef);
typedef void (*SetElapsedFn)(double);

static GetInfoFn getInfo;
static GetClientFn getClient;
static ClientBundleFn clientBundle;
static SendCommandFn sendCommand;
static SetElapsedFn setElapsed;
static NSString *lastArtworkKey;

static void emit(NSDictionary *payload) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (!json) return;
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static void publish(void) {
    getInfo(dispatch_get_main_queue(), ^(NSDictionary *info) {
        void (^send)(NSString *) = ^(NSString *bundle) {
            if (!info) {
                emit(@{@"state": @"none"});
                return;
            }
            NSMutableDictionary *out = [NSMutableDictionary dictionary];
            out[@"state"] = @"info";
            out[@"bundle"] = bundle ?: @"";
            id v;
            if ((v = info[@"kMRMediaRemoteNowPlayingInfoTitle"])) out[@"title"] = [v description];
            if ((v = info[@"kMRMediaRemoteNowPlayingInfoArtist"])) out[@"artist"] = [v description];
            if ((v = info[@"kMRMediaRemoteNowPlayingInfoAlbum"])) out[@"album"] = [v description];
            if ((v = info[@"kMRMediaRemoteNowPlayingInfoDuration"])) out[@"duration"] = v;
            if ((v = info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"])) out[@"elapsed"] = v;
            if ((v = info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"])) out[@"rate"] = v;
            NSDate *stamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
            if ([stamp isKindOfClass:[NSDate class]]) out[@"timestamp"] = @([stamp timeIntervalSince1970]);
            // Artwork only when the track changes: it is the heavy part.
            NSString *key = [NSString stringWithFormat:@"%@|%@", out[@"title"] ?: @"", out[@"artist"] ?: @""];
            NSData *art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
            if ([art isKindOfClass:[NSData class]] && ![key isEqualToString:lastArtworkKey]) {
                out[@"artwork"] = [art base64EncodedStringWithOptions:0];
                lastArtworkKey = key;
            }
            emit(out);
        };
        if (getClient && clientBundle) {
            getClient(dispatch_get_main_queue(), ^(id client) {
                send(client ? (__bridge NSString *)clientBundle(client) : nil);
            });
        } else {
            send(nil);
        }
    });
}

static BOOL load(void) {
    void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!h) return NO;
    RegisterFn registerFn = (RegisterFn)dlsym(h, "MRMediaRemoteRegisterForNowPlayingNotifications");
    getInfo = (GetInfoFn)dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
    getClient = (GetClientFn)dlsym(h, "MRMediaRemoteGetNowPlayingClient");
    clientBundle = (ClientBundleFn)dlsym(h, "MRNowPlayingClientGetBundleIdentifier");
    sendCommand = (SendCommandFn)dlsym(h, "MRMediaRemoteSendCommand");
    setElapsed = (SetElapsedFn)dlsym(h, "MRMediaRemoteSetElapsedTime");
    if (!registerFn || !getInfo) return NO;
    registerFn(dispatch_get_main_queue());
    return YES;
}

static void handleCommand(NSString *line) {
    NSArray<NSString *> *parts = [line componentsSeparatedByString:@" "];
    NSString *cmd = parts.firstObject;
    if (!sendCommand) return;
    if ([cmd isEqualToString:@"toggle"]) sendCommand(2, NULL);
    else if ([cmd isEqualToString:@"next"]) sendCommand(4, NULL);
    else if ([cmd isEqualToString:@"prev"]) sendCommand(5, NULL);
    else if ([cmd isEqualToString:@"seek"] && parts.count > 1 && setElapsed) setElapsed(parts[1].doubleValue);
}

/// `stream`: follow Now Playing until stdin closes. Called by perl as an XSUB; the two
/// arguments perl passes (interpreter, CV) are not used.
void islet_np_stream(void *perl, void *cv) {
    @autoreleasepool {
        if (!load()) {
            emit(@{@"state": @"unavailable"});
            return;
        }
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        for (NSString *name in @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                                 @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                                 @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification"]) {
            [nc addObserverForName:name object:nil queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *note) { publish(); }];
        }
        publish();

        dispatch_source_t input = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, dispatch_get_main_queue());
        __block NSMutableString *pending = [NSMutableString string];
        dispatch_source_set_event_handler(input, ^{
            char buffer[512];
            ssize_t n = read(STDIN_FILENO, buffer, sizeof buffer);
            if (n <= 0) exit(0);  // Islet is gone
            [pending appendString:[[NSString alloc] initWithBytes:buffer length:n encoding:NSUTF8StringEncoding] ?: @""];
            NSRange nl;
            while ((nl = [pending rangeOfString:@"\n"]).location != NSNotFound) {
                handleCommand([pending substringToIndex:nl.location]);
                [pending deleteCharactersInRange:NSMakeRange(0, nl.location + 1)];
            }
        });
        dispatch_resume(input);
        CFRunLoopRun();
    }
}

/// `probe`: print one line describing what is playing, then return (for --diagnose).
void islet_np_probe(void *perl, void *cv) {
    @autoreleasepool {
        if (!load()) {
            printf("unavailable\n");
            return;
        }
        __block BOOL done = NO;
        getInfo(dispatch_get_main_queue(), ^(NSDictionary *info) {
            NSString *title = [info[@"kMRMediaRemoteNowPlayingInfoTitle"] description];
            printf("%s\n", info ? (title ? title.UTF8String : "(untitled)") : "nil");
            done = YES;
        });
        NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:3];
        while (!done && [limit timeIntervalSinceNow] > 0) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, false);
        if (!done) printf("timeout\n");
        fflush(stdout);
    }
}
