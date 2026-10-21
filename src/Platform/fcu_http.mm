#include "fcu_http.h"

#include <chrono>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <unistd.h>


namespace fcu {

namespace {

// Written by delegate callbacks (NSURLSession queue), read by the waiting
// thread. Owned through shared_ptr by both sides so a callback that arrives
// after the caller gave up touches live memory.
struct RequestState {
    std::mutex mutex;
    std::condition_variable cv;
    bool done = false;
    std::string body;
    HttpMeta meta;
    std::string error;
    uint64_t maxBytes = 0;
    uint64_t received = 0;
    FILE* file = nullptr;
#ifdef FCU_DEBUG_HOOKS
    // Origin of the local test stub, set only for a request that itself goes to the
    // host:port configured in debug.api_base. Empty for every other request.
    std::string trustHost;
    int trustPort = 0;
#endif
};

} // namespace

} // namespace fcu

@interface FCUHttpDelegate : NSObject <NSURLSessionDataDelegate>
- (instancetype)initWithState:(std::shared_ptr<fcu::RequestState>)state;
@end

@implementation FCUHttpDelegate {
    std::shared_ptr<fcu::RequestState> _state;
}

- (instancetype)initWithState:(std::shared_ptr<fcu::RequestState>)state {
    if ((self = [super init])) _state = std::move(state);
    return self;
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest *))completionHandler {
    if (![request.URL.scheme isEqualToString:@"https"]) {
        std::lock_guard<std::mutex> lock(_state->mutex);
        _state->error = "Redirect to a non HTTPS URL refused";
        completionHandler(nil);
        return;
    }
    completionHandler(request);
}

#ifdef FCU_DEBUG_HOOKS
// Only the configured local test stub (self signed), at exactly its host and port, is
// accepted without validation. Redirects and every other request validate normally.
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler {
    NSURLProtectionSpace *space = challenge.protectionSpace;
    if ([space.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]
        && !_state->trustHost.empty() && space.serverTrust
        && [space.host isEqualToString:[NSString stringWithUTF8String:_state->trustHost.c_str()]]
        && space.port == _state->trustPort) {
        completionHandler(NSURLSessionAuthChallengeUseCredential,
                          [NSURLCredential credentialForTrust:space.serverTrust]);
        return;
    }
    completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
}
#endif

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        auto header = [http](NSString *name) {
            NSString *v = [http valueForHTTPHeaderField:name];
            return std::string(v ? v.UTF8String : "");
        };
        std::lock_guard<std::mutex> lock(_state->mutex);
        _state->meta.status = static_cast<int>(http.statusCode);
        _state->meta.link = header(@"Link");
        _state->meta.retryAfter = header(@"Retry-After");
        _state->meta.rateLimitRemaining = header(@"x-ratelimit-remaining");
        _state->meta.rateLimitReset = header(@"x-ratelimit-reset");
    }
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
    std::lock_guard<std::mutex> lock(_state->mutex);
    _state->received += data.length;
    if (_state->received > _state->maxBytes) {
        _state->error = "Response larger than the allowed size";
        [dataTask cancel];
        return;
    }
    // Error bodies (4xx) stay in memory so callers can read them; only 2xx streams to disk.
    if (_state->file && _state->meta.status >= 200 && _state->meta.status < 300) {
        if (fwrite(data.bytes, 1, data.length, _state->file) != data.length) {
            _state->error = "Could not write the download";
            [dataTask cancel];
        }
    } else {
        _state->body.append(static_cast<const char *>(data.bytes), data.length);
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    std::lock_guard<std::mutex> lock(_state->mutex);
    if (error && _state->error.empty()) {
        _state->error = error.localizedDescription.UTF8String ?: "Network error";
    }
    _state->done = true;
    _state->cv.notify_all();
}

@end

namespace fcu {

namespace {

#ifdef FCU_DEBUG_HOOKS
std::mutex g_logMutex;
std::vector<std::string> g_requestLog;
#endif

// Runs one request to completion; the response body (or download) ends up in `state`.
void perform(std::string const& url, HttpHeaders const& headers, abort_callback& abort,
             std::shared_ptr<RequestState> const& state) {
    @autoreleasepool {
        NSURL *nsurl = [NSURL URLWithString:[NSString stringWithUTF8String:url.c_str()]];
        if (!nsurl || ![nsurl.scheme isEqualToString:@"https"]) {
            throw std::runtime_error("Refusing a non HTTPS URL");
        }

#ifdef FCU_DEBUG_HOOKS
        {
            pfc::string8 base = fb2k::configStore::get()->getConfigString("foo_component_updater_mac.debug.api_base")->c_str();
            NSURL *stub = base.length() > 0 ? [NSURL URLWithString:[NSString stringWithUTF8String:base.c_str()]] : nil;
            if (stub && [stub.scheme isEqualToString:@"https"] && [stub.host isEqualToString:@"127.0.0.1"]
                && [nsurl.host isEqualToString:stub.host] && nsurl.port.integerValue == stub.port.integerValue) {
                state->trustHost = stub.host.UTF8String;
                state->trustPort = static_cast<int>(stub.port.integerValue);
            }
        }
#endif
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:nsurl];
        request.HTTPMethod = @"GET";
        request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        request.timeoutInterval = 30;
        [request setValue:[NSString stringWithUTF8String:userAgent().c_str()] forHTTPHeaderField:@"User-Agent"];
        for (auto const& h : headers) {
            [request setValue:[NSString stringWithUTF8String:h.second.c_str()]
                forHTTPHeaderField:[NSString stringWithUTF8String:h.first.c_str()]];
        }

        NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        config.timeoutIntervalForResource = 300;
        FCUHttpDelegate *delegate = [[FCUHttpDelegate alloc] initWithState:state];
        NSURLSession *session = [NSURLSession sessionWithConfiguration:config delegate:delegate delegateQueue:nil];
        NSURLSessionDataTask *task = [session dataTaskWithRequest:request];
        [task resume];

        bool cancelled = false;
        std::unique_lock<std::mutex> lock(state->mutex);
        while (!state->done) {
            state->cv.wait_for(lock, std::chrono::milliseconds(100));
            if (!cancelled && abort.is_aborting()) {
                cancelled = true;
                [task cancel];
            }
        }
        lock.unlock();
        [session finishTasksAndInvalidate];
        abort.check();
    }
}

void checkOutcome(RequestState const& state) {
    if (!state.error.empty()) throw std::runtime_error(state.error);
    if (state.meta.status < 200 || state.meta.status >= 300) {
        throw std::runtime_error("HTTP " + std::to_string(state.meta.status));
    }
}

} // namespace

std::string userAgent() {
    return std::string("foo_component_updater_mac/") + FCU_VERSION;
}

std::string httpGet(std::string const& url, HttpHeaders const& headers, abort_callback& abort, HttpMeta* meta) {
#ifdef FCU_DEBUG_HOOKS
    {
        std::lock_guard<std::mutex> lock(g_logMutex);
        g_requestLog.push_back(url);
    }
#endif
    auto state = std::make_shared<RequestState>();
    state->maxBytes = 32u * 1024 * 1024;
    perform(url, headers, abort, state);
    if (meta) {
        *meta = state->meta;
        if (meta->status < 200 || meta->status >= 300) meta->errorBody = state->body.substr(0, 1024);
    }
    checkOutcome(*state);
    return std::move(state->body);
}

void httpDownload(std::string const& url, std::string const& destPath, uint64_t maxBytes, abort_callback& abort) {
    auto state = std::make_shared<RequestState>();
    state->maxBytes = maxBytes;
    state->file = fopen(destPath.c_str(), "wb");
    if (!state->file) throw std::runtime_error("Could not create the download file");
    try {
        perform(url, {}, abort, state);
    } catch (...) {
        fclose(state->file);
        unlink(destPath.c_str());
        throw;
    }
    fclose(state->file);
    state->file = nullptr;
    try {
        checkOutcome(*state);
    } catch (...) {
        unlink(destPath.c_str());
        throw;
    }
}

std::string endpoint(std::string const& normal, std::string const& stubPath) {
#ifdef FCU_DEBUG_HOOKS
    pfc::string8 base = fb2k::configStore::get()->getConfigString("foo_component_updater_mac.debug.api_base")->c_str();
    if (base.length() > 0) return std::string(base.c_str()) + stubPath;
#else
    (void)stubPath;
#endif
    return normal;
}

#ifdef FCU_DEBUG_HOOKS
std::vector<std::string> requestLog() {
    std::lock_guard<std::mutex> lock(g_logMutex);
    return g_requestLog;
}
#endif

} // namespace fcu
