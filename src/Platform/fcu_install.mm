#include "fcu_install.h"

#include <climits>
#include <ctime>
#include <fts.h>
#include <functional>
#include <spawn.h>
#include <stdexcept>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/xattr.h>
#include <unistd.h>
#include <vector>

#include <Security/Security.h>

#include "fcu_http.h"
#include "../Core/package_layout.h"

extern char **environ;

namespace fcu {

namespace {

constexpr uint64_t kMaxDownloadBytes = 100ull * 1024 * 1024;

// The message is shown to the user as is.
struct Refused : std::runtime_error {
    using std::runtime_error::runtime_error;
};

void require(bool ok, char const *message) {
    if (!ok) throw Refused(message);
}

NSFileManager *fm() { return NSFileManager.defaultManager; }
NSString *ns(std::string const& s) { return [NSString stringWithUTF8String:s.c_str()]; }
NSString *join(NSString *a, NSString *b) { return [a stringByAppendingPathComponent:b]; }

bool isDirectory(NSString *path) {
    BOOL dir = NO;
    return [fm() fileExistsAtPath:path isDirectory:&dir] && dir;
}

// lstat: a link to a directory does not count.
bool isRealDirectory(NSString *path) {
    struct stat st;
    return lstat(path.fileSystemRepresentation, &st) == 0 && S_ISDIR(st.st_mode);
}

void makeDirectory(NSString *path) {
    require([fm() createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil], "Could not create a folder in the foobar2000 profile.");
}

bool validName(std::string const& name) { return !name.empty() && name[0] != '.' && name.find('/') == std::string::npos; }

// get_my_full_path() is <profile>/user-components/<name>/<name>.component on Mac.
NSString *userComponentsDir() {
    return ns(core_api::get_my_full_path()).stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
}

NSString *rootDir() { return join(userComponentsDir().stringByDeletingLastPathComponent, @"foo_component_updater_mac"); }
NSString *backupSlot(std::string const& name) { return join(join(rootDir(), @"backup"), ns(name)); }
NSString *bundleIn(NSString *dir, std::string const& name) { return join(join(dir, ns(name)), ns(name + ".component")); }

void run(std::vector<std::string> const& args, abort_callback& abort, char const *failure) {
    std::vector<char *> argv;
    for (auto const& a : args) argv.push_back(const_cast<char *>(a.c_str()));
    argv.push_back(nullptr);
    pid_t pid;
    require(posix_spawn(&pid, argv[0], nullptr, nullptr, argv.data(), environ) == 0, failure);
    int status = 0;
    while (waitpid(pid, &status, WNOHANG) == 0) {
        if (abort.is_aborting()) {
            kill(pid, SIGTERM);
            waitpid(pid, &status, 0);
            abort.check();
        }
        usleep(50 * 1000);
    }
    require(WIFEXITED(status) && WEXITSTATUS(status) == 0, failure);
}

// One install or restore: a private work folder, removed on every way out. The caller runs one
// operation at a time, so anything already in work/ is left over from a crash.
struct Job {
    std::string name;
    NSString *work = nil;

    Job(std::string const& n) : name(n) {
        require(validName(n), "Invalid component name.");
        require(isDirectory(installed()), "This component is not installed in the foobar2000 profile.");
        NSString *parent = join(rootDir(), @"work");
        [fm() removeItemAtPath:parent error:nil];
        makeDirectory(parent);
        std::string pattern = join(parent, @"XXXXXX").fileSystemRepresentation;
        require(mkdtemp(pattern.data()) != nullptr, "Could not create a work folder.");
        work = ns(pattern);
    }
    ~Job() {
        if (work) [fm() removeItemAtPath:work error:nil];
    }

    NSString *installed() const { return bundleIn(userComponentsDir(), name); }
    NSString *staged() const { return bundleIn(join(work, @"stage"), name); }
};

// Every entry is a regular file, a folder or a link that resolves inside the bundle; the
// quarantine attribute is removed and must stay gone (a quarantined bundle does not load).
void sanitize(NSString *bundle) {
    char realRoot[PATH_MAX];
    require(realpath(bundle.fileSystemRepresentation, realRoot), "Could not read the extracted component.");
    std::string const prefix = std::string(realRoot) + "/";

    char *roots[] = {const_cast<char *>(bundle.fileSystemRepresentation), nullptr};
    FTS *fts = fts_open(roots, FTS_PHYSICAL | FTS_NOCHDIR, nullptr);
    require(fts != nullptr, "Could not read the extracted component.");
    struct Close {
        FTS *f;
        ~Close() { fts_close(f); }
    } close{fts};

    while (FTSENT *e = fts_read(fts)) {
        if (e->fts_info == FTS_DP) continue;
        if (e->fts_info == FTS_SL || e->fts_info == FTS_SLNONE) {
            char target[PATH_MAX];
            if (!realpath(e->fts_path, target) || (strcmp(target, realRoot) != 0 && strncmp(target, prefix.c_str(), prefix.size()) != 0)) {
                throw Refused(std::string("The package contains a link that points outside the component: ") + e->fts_name);
            }
        } else if (e->fts_info != FTS_D && e->fts_info != FTS_F) {
            throw Refused(std::string("The package contains a file of an unsupported type: ") + e->fts_name);
        }
        removexattr(e->fts_path, "com.apple.quarantine", XATTR_NOFOLLOW);
        require(getxattr(e->fts_path, "com.apple.quarantine", nullptr, 0, 0, XATTR_NOFOLLOW) < 0, "The quarantine flag could not be removed from the package.");
    }
}

id staticCode(NSString *bundle) {
    SecStaticCodeRef code = nullptr;
    require(SecStaticCodeCreateWithPath((__bridge CFURLRef)[NSURL fileURLWithPath:bundle], kSecCSDefaultFlags, &code) == errSecSuccess,
            "Could not read the code signature of the component.");
    return CFBridgingRelease(code);
}

NSString *teamId(id code) {
    CFDictionaryRef info = nullptr;
    if (SecCodeCopySigningInformation((__bridge SecStaticCodeRef)code, kSecCSSigningInformation, &info) != errSecSuccess) return @"";
    NSDictionary *d = CFBridgingRelease(info);
    return d[(__bridge NSString *)kSecCodeInfoTeamIdentifier] ?: @"";
}

NSString *bundleId(NSString *bundle) {
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:join(join(bundle, @"Contents"), @"Info.plist")];
    return info[@"CFBundleIdentifier"] ?: @"";
}

// The candidate must be validly signed (ad hoc is fine) and be the same product as the
// installed bundle: same bundle identifier and, when the installed one has a Team ID, the same Team ID.
void verifyIdentity(NSString *candidate, NSString *installed) {
    id code = staticCode(candidate);
    OSStatus status = SecStaticCodeCheckValidity((__bridge SecStaticCodeRef)code,
        kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode, nullptr);
    if (status != errSecSuccess) {
        NSString *why = CFBridgingRelease(SecCopyErrorMessageString(status, nullptr));
        throw Refused(std::string("The code signature of the new version is not valid (") + (why ? why.UTF8String : "unknown error") + ").");
    }
    require([bundleId(candidate) isEqualToString:bundleId(installed)], "The new version has a different bundle identifier than the installed one.");
    NSString *installedTeam = teamId(staticCode(installed)), *newTeam = teamId(code);
    if (installedTeam.length != 0 && ![installedTeam isEqualToString:newTeam]) {
        throw Refused(std::string("The new version is signed by a different developer than the installed one (installed: ") + installedTeam.UTF8String
                      + ", new: " + (newTeam.length ? newTeam.UTF8String : "none") + ").");
    }
}

// Copies the installed bundle to the single backup slot; the slot is replaced in one step.
void keepBackup(Job const& job, std::string const& installedVersion, abort_callback& abort) {
    NSString *fresh = join(job.work, @"backup");
    makeDirectory(fresh);
    run({"/usr/bin/ditto", "--noqtn", job.installed().fileSystemRepresentation, join(fresh, ns(job.name + ".component")).fileSystemRepresentation}, abort,
        "Could not back up the installed version.");
    NSData *json = [NSJSONSerialization dataWithJSONObject:@{@"version": ns(installedVersion), @"saved": @((long long)time(nullptr))} options:0 error:nil];
    require([json writeToFile:join(fresh, @"backup.json") atomically:NO], "Could not back up the installed version.");

    NSString *slot = backupSlot(job.name);
    makeDirectory(slot.stringByDeletingLastPathComponent);
    if ([fm() fileExistsAtPath:slot]) {
        require([fm() replaceItemAtURL:[NSURL fileURLWithPath:slot] withItemAtURL:[NSURL fileURLWithPath:fresh] backupItemName:nil options:0
                      resultingItemURL:nil error:nil], "Could not replace the previous backup.");
    } else {
        require(rename(fresh.fileSystemRepresentation, slot.fileSystemRepresentation) == 0, "Could not store the backup.");
    }
}

// Steps shared by install and restore: the new bundle already sits at job.staged().
void finish(Job const& job, std::string const& installedVersion, abort_callback& abort) {
    sanitize(job.staged());
    verifyIdentity(job.staged(), job.installed());
    keepBackup(job, installedVersion, abort);

    // The folder moves into place in one rename, so foobar2000 never sees a half written pending/<name>.
    NSString *pending = join(userComponentsDir(), @"pending");
    makeDirectory(pending);
    NSString *target = join(pending, ns(job.name));
    [fm() removeItemAtPath:target error:nil]; // an uninstall marker (file) or an older staged folder
    require(rename(job.staged().stringByDeletingLastPathComponent.fileSystemRepresentation, target.fileSystemRepresentation) == 0,
            "Could not stage the new version.");
}

InstallOutcome guarded(std::function<void()> const& body) {
    InstallOutcome out;
    @autoreleasepool {
        try {
            body();
            out.ok = true;
        } catch (std::exception const& e) {
            out.message = e.what();
        } catch (...) {
            out.message = "Unexpected error.";
        }
    }
    return out;
}

} // namespace

InstallOutcome installUpdate(std::string const& name, std::string const& installedVersion, std::string const& url, abort_callback& abort) {
    return guarded([&] {
        Job job(name);
        NSString *zip = join(job.work, @"package.zip");
        try {
            httpDownload(url, zip.fileSystemRepresentation, kMaxDownloadBytes, abort);
        } catch (std::runtime_error const& e) {
            throw Refused(std::string("The download failed: ") + e.what());
        }

        NSData *bytes = [NSData dataWithContentsOfFile:zip options:NSDataReadingMappedAlways error:nil];
        require(bytes != nil, "Could not read the download.");
        PackageCheck check = checkPackageLayout(std::string_view(static_cast<char const *>(bytes.bytes), bytes.length), name);
        if (!check.ok) throw Refused(check.error);

        NSString *extracted = join(job.work, @"x");
        run({"/usr/bin/ditto", "-x", "-k", "--noqtn", zip.fileSystemRepresentation, extracted.fileSystemRepresentation}, abort, "Could not extract the package.");
        // A zip can hold links: both levels must be real folders before anything is moved out of them.
        NSString *source = join(join(extracted, @"mac"), ns(name + ".component"));
        if (!isRealDirectory(join(extracted, @"mac")) || !isRealDirectory(source)) throw Refused("The package does not hold a plain mac/" + name + ".component folder.");
        makeDirectory(job.staged().stringByDeletingLastPathComponent);
        require(rename(source.fileSystemRepresentation, job.staged().fileSystemRepresentation) == 0, "Could not prepare the new version.");
        finish(job, installedVersion, abort);
    });
}

InstallOutcome restorePrevious(std::string const& name, std::string const& installedVersion, abort_callback& abort) {
    return guarded([&] {
        Job job(name);
        NSString *backup = join(backupSlot(name), ns(name + ".component"));
        require(isRealDirectory(backup), "There is no previous version to restore.");
        makeDirectory(job.staged().stringByDeletingLastPathComponent);
        run({"/usr/bin/ditto", "--noqtn", backup.fileSystemRepresentation, job.staged().fileSystemRepresentation}, abort, "Could not copy the previous version.");
        finish(job, installedVersion, abort);
    });
}

bool isStaged(std::string const& name) {
    return validName(name) && isDirectory(bundleIn(join(userComponentsDir(), @"pending"), name));
}

bool backupVersion(std::string const& name, std::string& version) {
    if (!validName(name)) return false;
    @autoreleasepool {
        NSString *slot = backupSlot(name);
        NSData *json = [NSData dataWithContentsOfFile:join(slot, @"backup.json")];
        id parsed = json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:nil] : nil;
        NSString *v = [parsed isKindOfClass:NSDictionary.class] ? parsed[@"version"] : nil;
        if (![v isKindOfClass:NSString.class] || !isRealDirectory(join(slot, ns(name + ".component")))) return false;
        version = v.UTF8String;
        return true;
    }
}

} // namespace fcu
