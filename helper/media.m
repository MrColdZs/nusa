// Helper Now Playing. macOS 15.4+ cuma ngizinin proses bawaan Apple baca MediaRemote,
// jadi dylib ini dimuat dari /usr/bin/perl. Keluaran: satu baris JSON per perubahan.
// Masukan stdin: toggle, next, prev, seek <detik>.
#import <Foundation/Foundation.h>
#include <dlfcn.h>

typedef void (*GetInfo)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*GetPlaying)(dispatch_queue_t, void (^)(BOOL));
typedef void (*Register)(dispatch_queue_t);
typedef bool (*SendCommand)(int, NSDictionary *);
typedef void (*SetTime)(double);
typedef void (*GetClient)(dispatch_queue_t, void (^)(id));
typedef NSString *(*ClientString)(id);

static GetInfo getInfo;
static GetPlaying getPlaying;
static SendCommand sendCommand;
static SetTime setTime;
static GetClient getClient;
static ClientString clientBundle, clientParent;
static NSString *lastArtHash;

static void emit(NSDictionary *d) {
    NSData *j = [NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
    if (!j) return;
    fwrite(j.bytes, 1, j.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static void refresh(void) {
    getInfo(dispatch_get_main_queue(), ^(NSDictionary *info) {
        getPlaying(dispatch_get_main_queue(), ^(BOOL playing) {
            NSMutableDictionary *o = [NSMutableDictionary dictionary];
            o[@"playing"] = @(playing);
            id v;
            if ((v = info[@"kMRMediaRemoteNowPlayingInfoTitle"])) o[@"title"] = v;
            if ((v = info[@"kMRMediaRemoteNowPlayingInfoArtist"])) o[@"artist"] = v;
            if ((v = info[@"kMRMediaRemoteNowPlayingInfoAlbum"])) o[@"album"] = v;
            if ((v = info[@"kMRMediaRemoteNowPlayingInfoDuration"])) o[@"duration"] = v;
            if ((v = info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"])) o[@"elapsed"] = v;
            if ((v = info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"])) o[@"rate"] = v;
            NSDate *ts = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
            if (ts) o[@"timestamp"] = @(ts.timeIntervalSince1970);
            NSData *art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
            if (art.length) {
                NSString *h = [NSString stringWithFormat:@"%lu-%lu", (unsigned long)art.length, (unsigned long)art.hash];
                o[@"artId"] = h;
                if (![h isEqualToString:lastArtHash]) {
                    lastArtHash = h;
                    o[@"art"] = [art base64EncodedStringWithOptions:0];
                }
            }
            if (!getClient) { emit(o); return; }
            getClient(dispatch_get_main_queue(), ^(id client) {
                // App berbasis WebKit kebaca sebagai proses WebKit; yang dipakai app induknya
                NSString *b = client && clientParent ? clientParent(client) : nil;
                if (!b.length && client && clientBundle) b = clientBundle(client);
                if (b.length) o[@"bundle"] = b;
                emit(o);
            });
        });
    });
}

static void command(NSString *line) {
    if ([line isEqualToString:@"toggle"]) sendCommand(2, nil);
    else if ([line isEqualToString:@"pause"]) sendCommand(1, nil);
    else if ([line isEqualToString:@"next"]) sendCommand(4, nil);
    else if ([line isEqualToString:@"prev"]) sendCommand(5, nil);
    else if ([line hasPrefix:@"seek "]) setTime([[line substringFromIndex:5] doubleValue]);
    else if ([line isEqualToString:@"refresh"]) refresh();
}

__attribute__((visibility("default"))) void nusa_media(void *a, void *b) {
    void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    getInfo = dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
    getPlaying = dlsym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    sendCommand = dlsym(h, "MRMediaRemoteSendCommand");
    setTime = dlsym(h, "MRMediaRemoteSetElapsedTime");
    getClient = dlsym(h, "MRMediaRemoteGetNowPlayingClient");
    clientBundle = dlsym(h, "MRNowPlayingClientGetBundleIdentifier");
    clientParent = dlsym(h, "MRNowPlayingClientGetParentAppBundleIdentifier");
    Register reg = dlsym(h, "MRMediaRemoteRegisterForNowPlayingNotifications");
    reg(dispatch_get_main_queue());
    for (NSString *n in @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                          @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                          @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification"]) {
        [NSNotificationCenter.defaultCenter addObserverForName:n object:nil queue:nil usingBlock:^(NSNotification *x) { refresh(); }];
    }
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        char buf[256];
        while (fgets(buf, sizeof buf, stdin)) {
            NSString *s = [[NSString stringWithUTF8String:buf] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            dispatch_async(dispatch_get_main_queue(), ^{ command(s); });
        }
        exit(0); // app induk mati, helper ikut mati
    });
    refresh();
    dispatch_main();
}
