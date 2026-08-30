// The MediaRemote bridge: the only non-Swift code in CreativeNotch.
//
// WHY THIS EXISTS
// ---------------
// `mediaremoted` hands now-playing metadata only to processes whose
// code-signing identifier begins `com.apple.`. CreativeNotch is signed
// `com.gcdz.creativenotch` and gets an empty dictionary. `/usr/bin/perl`
// ships signed `com.apple.perl`, and the gate inspects the HOST process's
// identity rather than the identity of loaded code — so a dylib dlopened
// into perl inherits the exemption. That is the whole mechanism, and it is
// verified in docs/research/2026-08-29-media-metadata-feasibility.md.
//
// This file is loaded by Resources/media-helper.pl, which installs
// `cn_media_stream` as an XSUB and calls it. Everything below runs inside
// the perl process.
//
// ⚠️ THE WORK MUST NOT MOVE INTO A CONSTRUCTOR.
// A `__attribute__((constructor))` runs during `dlopen` while dyld holds
// the loader lock. MediaRemote's XPC round-trip cannot complete there, so
// the callback simply times out — a result indistinguishable from the gate
// refusing us, and one that would get this technique wrongly written off.
// The spike hit exactly that. Do the work in the exported function, after
// the library is loaded.

#import <Foundation/Foundation.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#include "include/bridge.h"

// MediaRemote lives in the dyld shared cache; there is no file at this
// path, but `dlopen` resolves it from the cache all the same.
static const char *const kMediaRemotePath =
    "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote";

typedef void (*CNGetNowPlayingInfo)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*CNGetApplicationIsPlaying)(dispatch_queue_t, void (^)(Boolean));
typedef void (*CNRegisterForNotifications)(dispatch_queue_t);

static CNGetNowPlayingInfo gGetNowPlayingInfo;
static CNGetApplicationIsPlaying gGetApplicationIsPlaying;

// MediaRemote's dictionary keys and notification names are exported as
// CFStringRef constants whose *values* equal their symbol names. We resolve
// the symbol when we can and fall back to the literal when a future macOS
// stops exporting it, so a missing symbol degrades one field rather than
// killing the stream.
static NSString *CNConstant(void *handle, const char *symbol) {
    CFStringRef *slot = (CFStringRef *)dlsym(handle, symbol);
    if (slot != NULL && *slot != NULL) {
        return (__bridge NSString *)*slot;
    }
    return [NSString stringWithUTF8String:symbol];
}

// Values arrive loosely typed. Coerce the ones we can name and drop the
// rest rather than letting a surprise type reach NSJSONSerialization,
// which would throw on a non-JSON object.
static NSString *CNString(NSDictionary *info, NSString *key) {
    if (key == nil) { return nil; }
    id value = info[key];
    if ([value isKindOfClass:[NSString class]]) { return value; }
    if ([value isKindOfClass:[NSNumber class]]) { return [value stringValue]; }
    return nil;
}

// Diagnostics carry counts and error kinds only. Titles and artists are
// user data and never touch stderr.
static void CNLog(const char *format, ...) {
    va_list args;
    va_start(args, format);
    fprintf(stderr, "cn-media-bridge: ");
    vfprintf(stderr, format, args);
    fputc('\n', stderr);
    va_end(args);
    fflush(stderr);
}

/// Serialises one now-playing dictionary onto stdout as a single JSON line.
///
/// The object is built with NSJSONSerialization, never with printf. Real
/// track titles contain quotes, backslashes, newlines and emoji, and a
/// hand-rolled formatter emits invalid JSON on ordinary music.
static void CNEmit(NSDictionary *info, BOOL playing) {
    @autoreleasepool {
        NSMutableDictionary *payload = [NSMutableDictionary dictionary];

        // Keys are exactly MediaPayload's CodingKeys. A mismatch fails
        // SILENTLY: decodeIfPresent yields empty fields instead of an
        // error, so nothing downstream would catch a typo here.
        payload[@"title"] = CNString(info, @"kMRMediaRemoteNowPlayingInfoTitle") ?: @"";
        payload[@"artist"] = CNString(info, @"kMRMediaRemoteNowPlayingInfoArtist") ?: @"";
        payload[@"album"] = CNString(info, @"kMRMediaRemoteNowPlayingInfoAlbum") ?: @"";

        // `playing` is queried, never inferred from notification ordering.
        // See CNPlayingFromRate for why the queried value beats the
        // dictionary's own playback rate.
        //
        // Reported as measured, with no cleverness on top. With nothing
        // playing at all MediaRemote returns an empty info dictionary and
        // still answers YES to the is-playing query; that combination is
        // passed through rather than second-guessed, because the only
        // available correction — "no title means not playing" — would
        // misreport genuinely playing media that carries no title, which
        // is exactly what QuickTime Player publishes. MediaPayload.snapshot
        // already resolves a title-less payload to "nothing playing".
        payload[@"playing"] = playing ? @YES : @NO;

        NSString *contentID =
            CNString(info, @"kMRMediaRemoteNowPlayingInfoContentItemIdentifier")
            ?: CNString(info, @"kMRMediaRemoteNowPlayingInfoExternalContentIdentifier")
            ?: CNString(info, @"kMRMediaRemoteNowPlayingInfoUniqueIdentifier");
        if (contentID != nil) {
            payload[@"contentID"] = contentID;
        }

        // Artwork is OMITTED ENTIRELY when absent — never "" and never
        // null. It flaps present/absent for one unchanged track (the spike
        // saw 138061 → 0 → 0 → 138061 …), and the consumer caches by track
        // identity precisely because of that. An empty string would look
        // like real artwork data and defeat the cache.
        id artwork = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
        if ([artwork isKindOfClass:[NSData class]] && [artwork length] > 0) {
            payload[@"artwork"] = [artwork base64EncodedStringWithOptions:0];
        }

        NSError *error = nil;
        NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&error];
        if (json == nil) {
            CNLog("serialisation failed: %s", error.domain.UTF8String ?: "unknown");
            return;
        }

        // Newline-delimited JSON, '\n' only. The consumer splits on '\n';
        // a '\r\n' emitter would leave a trailing '\r' on every line, which
        // still decodes as JSON but silently pollutes every value.
        size_t written = fwrite(json.bytes, 1, json.length, stdout);
        if (written != json.length || fputc('\n', stdout) == EOF || fflush(stdout) != 0) {
            // The parent's pipe is gone. Leaving would orphan us.
            CNLog("stdout closed, exiting");
            exit(0);
        }
    }
}

/// Fallback playing signal: the dictionary's own playback rate.
///
/// ⚠️ Only a fallback, and measured to be wrong. On macOS 26.6.2 Spotify
/// publishes `kMRMediaRemoteNowPlayingInfoPlaybackRate` = 1 while PAUSED
/// and omits the key entirely while PLAYING. Sampled against Spotify's own
/// `player state`, the rate was right 1 time in 5; the queried
/// `MRMediaRemoteGetNowPlayingApplicationIsPlaying` was right 5 times in 5.
/// Deriving `playing` from the rate alone therefore reports the notch's
/// play indicator backwards for the most common player on this machine.
///
/// This is used only if that symbol ever disappears, since a stale answer
/// still beats no answer.
static BOOL CNPlayingFromRate(NSDictionary *info) {
    id rate = info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"];
    return [rate isKindOfClass:[NSNumber class]] && [rate doubleValue] > 0.0;
}

/// Asks MediaRemote for the current state and emits one line for it.
///
/// Both reads are queried fresh over XPC rather than inferred from which
/// notification arrived — the spike saw notification ordering lag reality.
/// They land on the same serial queue, so two overlapping changes cannot
/// interleave halves of a line.
static void CNEmitCurrent(dispatch_queue_t queue) {
    if (gGetNowPlayingInfo == NULL) { return; }
    gGetNowPlayingInfo(queue, ^(CFDictionaryRef raw) {
        NSDictionary *info = (__bridge NSDictionary *)raw ?: @{};
        if (gGetApplicationIsPlaying == NULL) {
            CNEmit(info, CNPlayingFromRate(info));
            return;
        }
        gGetApplicationIsPlaying(queue, ^(Boolean playing) {
            CNEmit(info, playing ? YES : NO);
        });
    });
}

/// ⚠️ Held in a STATIC on purpose. This file compiles under ARC, which
/// manages dispatch objects: a local `dispatch_source_t` would be released
/// the moment the function below returned, the source would never fire,
/// and the helper would silently stop noticing its parent's death — it
/// outlived its parent exactly that way during verification.
static dispatch_source_t gStdinSource;

/// Exits the moment stdin reaches EOF.
///
/// THIS IS THE ORPHAN-PREVENTION MECHANISM. The runloop runs indefinitely,
/// so without this a helper outlives the app that spawned it and keeps
/// reading the user's media forever. The parent holds the write end of our
/// stdin; when the parent dies the pipe closes and read() here returns 0.
///
/// ⚠️ The watchdog gets its OWN serial queue, and it must keep it. DO NOT
/// merge it onto the emit queue as a tidy-up: `CNEmit` calls a *blocking*
/// `fwrite`/`fflush` on stdout, and a shared serial queue would sit behind
/// that write. A parent that signals shutdown by closing our stdin while
/// no longer draining our stdout would then wedge us — the write blocks on
/// a full pipe forever and the EOF handler that would have exited us never
/// gets to run. Separate queues mean the watchdog can always fire, whatever
/// the emit side is doing.
static void CNExitWhenStdinCloses(void) {
    // Static for the same ARC reason as gStdinSource below.
    static dispatch_queue_t watchdogQueue;
    watchdogQueue = dispatch_queue_create("com.gcdz.creativenotch.media-bridge.stdin",
                                          DISPATCH_QUEUE_SERIAL);
    gStdinSource =
        dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, watchdogQueue);
    if (gStdinSource == NULL) {
        CNLog("could not watch stdin; refusing to run unsupervised");
        exit(1);
    }
    dispatch_source_set_event_handler(gStdinSource, ^{
        char scratch[1024];
        ssize_t n = read(STDIN_FILENO, scratch, sizeof scratch);
        if (n > 0) { return; }                                  // input we ignore
        if (n < 0 && (errno == EINTR || errno == EAGAIN)) { return; }
        exit(0);                                                 // EOF: parent is gone
    });
    dispatch_resume(gStdinSource);
}

void cn_media_stream(void *interp_unused, void *cv_unused) {
    (void)interp_unused;
    (void)cv_unused;

    @autoreleasepool {
        // Writing to a dead pipe should end us through our own exit path,
        // not through a signal we cannot report on.
        signal(SIGPIPE, SIG_IGN);

        void *handle = dlopen(kMediaRemotePath, RTLD_LAZY);
        if (handle == NULL) {
            CNLog("dlopen MediaRemote failed");
            exit(1);
        }

        gGetNowPlayingInfo =
            (CNGetNowPlayingInfo)dlsym(handle, "MRMediaRemoteGetNowPlayingInfo");
        gGetApplicationIsPlaying =
            (CNGetApplicationIsPlaying)dlsym(handle,
                                             "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
        if (gGetApplicationIsPlaying == NULL) {
            CNLog("MRMediaRemoteGetNowPlayingApplicationIsPlaying missing; "
                  "falling back to the playback rate, which is unreliable");
        }
        CNRegisterForNotifications registerForNotifications =
            (CNRegisterForNotifications)dlsym(handle,
                                              "MRMediaRemoteRegisterForNowPlayingNotifications");
        if (gGetNowPlayingInfo == NULL || registerForNotifications == NULL) {
            CNLog("MediaRemote symbols missing");
            exit(1);
        }

        // Replies and emissions are serialised on one queue so two
        // overlapping callbacks cannot interleave halves of a line.
        // Static for the same ARC reason as gStdinSource: this function's
        // scope ends long before the queue's work does.
        static dispatch_queue_t queue;
        queue = dispatch_queue_create("com.gcdz.creativenotch.media-bridge",
                                      DISPATCH_QUEUE_SERIAL);

        CNExitWhenStdinCloses();

        // Push, not polling: MediaRemote posts to the local notification
        // centre once we register. One user action produces about six
        // notifications; coalescing is the consumer's job, not ours.
        registerForNotifications(dispatch_get_main_queue());

        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        NSArray<NSString *> *names = @[
            CNConstant(handle, "kMRMediaRemoteNowPlayingInfoDidChangeNotification"),
            CNConstant(handle, "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"),
        ];
        for (NSString *name in names) {
            [center addObserverForName:name
                                object:nil
                                 queue:nil
                            usingBlock:^(NSNotification *note) {
                                (void)note;
                                CNEmitCurrent(queue);
                            }];
        }

        // Emit once immediately, so a freshly spawned helper reports the
        // current track rather than waiting for the user to change it.
        CNEmitCurrent(queue);

        CNLog("streaming");
    }

    // Indefinitely. The spike's 12-second bound was scaffolding; the only
    // way out is stdin EOF, a signal, or a dead stdout.
    CFRunLoopRun();
}
