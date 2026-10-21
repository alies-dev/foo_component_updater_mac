#include "fcu_install.h"

#include <cerrno>
#include <climits>
#include <ctime>
#include <fts.h>
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

// Exceptions thrown here carry the message that is shown to the user as is.
void require(bool ok, char const *message) {
    if (!ok) throw std::runtime_error(message);
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

// What the child has written below `dir`, summed from lstat sizes (links are not followed). A folder or file that cannot be
// examined (no read access, a failing stat, a walk that ends early) leaves the total partial: its name goes to `unreadable`.
// Only an entry that vanished between listing and stat is skipped; the child may be creating or removing entries.
uint64_t writtenBytes(NSString *dir, std::string& unreadable) {
    char *roots[] = {const_cast<char *>(dir.fileSystemRepresentation), nullptr};
    FTS *fts = fts_open(roots, FTS_PHYSICAL | FTS_NOCHDIR, nullptr);
    if (!fts) {
        unreadable = "the extraction folder";
        return 0;
    }
    uint64_t total = 0;
    FTSENT *e;
    while (errno = 0, (e = fts_read(fts))) {
        if (e->fts_info == FTS_DNR || e->fts_info == FTS_ERR || e->fts_info == FTS_NS) {
            if (e->fts_errno == ENOENT) continue;
            unreadable = e->fts_name;
            break;
        }
        if (S_ISREG(e->fts_statp->st_mode)) total += e->fts_statp->st_size;
    }
    if (!e && errno != 0 && errno != ENOENT) unreadable = "the extraction folder";
    fts_close(fts);
    return total;
}

// SIGKILL, then wait until the child is gone: a wait cut short by a signal is retried, so no zombie outlives the cleanup of the
// work folder. Any other error (ECHILD) means there is nothing left to wait for.
void killAndReap(pid_t pid) {
    kill(pid, SIGKILL);
    int status;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
    }
}

// Runs a tool and waits for it. With `watch`, the tool is killed once a poll finds more than the package size cap below that
// folder, or finds output it cannot measure: the zip's own size fields (checked before) are not what ditto follows. Abort kills it too.
void run(std::vector<std::string> const& args, abort_callback& abort, char const *failure, NSString *watch = nil) {
    std::vector<char *> argv;
    for (auto const& a : args) argv.push_back(const_cast<char *>(a.c_str()));
    argv.push_back(nullptr);
    pid_t pid;
    require(posix_spawn(&pid, argv[0], nullptr, nullptr, argv.data(), environ) == 0, failure);
    // Empty when the output is fine, otherwise the user readable refusal.
    auto refusal = [&]() -> std::string {
        if (!watch) return "";
        std::string unreadable;
        uint64_t const bytes = writtenBytes(watch, unreadable);
        if (!unreadable.empty()) return "The package contains a folder or file that cannot be examined: " + unreadable;
        if (bytes > kMaxPackageUncompressedBytes) return "The package expands to more than " + std::to_string(kMaxPackageUncompressedBytes >> 20) + " MB.";
        return "";
    };
    int status = 0;
    pid_t waited;
    std::string why;
    while ((waited = waitpid(pid, &status, WNOHANG)) == 0 || (waited < 0 && errno == EINTR)) {
        if (abort.is_aborting() || !(why = refusal()).empty()) {
            killAndReap(pid);
            abort.check();
            throw std::runtime_error(why);
        }
        usleep(100 * 1000);
    }
    why = refusal(); // ditto can finish between two polls
    if (!why.empty()) throw std::runtime_error(why);
    require(waited == pid && WIFEXITED(status) && WEXITSTATUS(status) == 0, failure);
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
        if (!work || [fm() removeItemAtPath:work error:nil]) return;
        // A refused package may carry folders without access rights: give them back, then remove again.
        try {
            abort_callback_dummy none;
            run({"/bin/chmod", "-R", "u+rwX", work.fileSystemRepresentation}, none, "");
        } catch (...) {
        }
        [fm() removeItemAtPath:work error:nil];
    }

    NSString *installed() const { return bundleIn(userComponentsDir(), name); }
    NSString *staged() const { return bundleIn(join(work, @"stage"), name); }
};

// Calls visit for every entry below root (folders before their content). Whatever fts could not read (a folder
// without read permission, a failing stat, an error that ends the walk) is a refusal: unread content is unexamined.
template <class F>
void walkTree(NSString *root, F const& visit) {
    char *roots[] = {const_cast<char *>(root.fileSystemRepresentation), nullptr};
    FTS *fts = fts_open(roots, FTS_PHYSICAL | FTS_NOCHDIR, nullptr);
    require(fts != nullptr, "Could not read the extracted package.");
    struct Close {
        FTS *f;
        ~Close() { fts_close(f); }
    } close{fts};

    errno = 0;
    while (FTSENT *e = fts_read(fts)) {
        if (e->fts_info == FTS_DNR || e->fts_info == FTS_ERR || e->fts_info == FTS_NS) {
            throw std::runtime_error(std::string("The package contains a folder or file that cannot be examined: ") + e->fts_name);
        }
        if (e->fts_info != FTS_DP) visit(e);
    }
    require(errno == 0, "The package could not be examined completely.");
}

// Every entry is a regular file, a folder or a link that resolves inside the bundle; the
// quarantine attribute is removed and must stay gone (a quarantined bundle does not load).
void sanitize(NSString *bundle) {
    char realRoot[PATH_MAX];
    require(realpath(bundle.fileSystemRepresentation, realRoot), "Could not read the extracted component.");
    std::string const prefix = std::string(realRoot) + "/";

    walkTree(bundle, [&](FTSENT const *e) {
        if (e->fts_info == FTS_SL || e->fts_info == FTS_SLNONE) {
            char target[PATH_MAX];
            if (!realpath(e->fts_path, target) || (strcmp(target, realRoot) != 0 && strncmp(target, prefix.c_str(), prefix.size()) != 0)) {
                throw std::runtime_error(std::string("The package contains a link that points outside the component: ") + e->fts_name);
            }
        } else if (e->fts_info != FTS_D && e->fts_info != FTS_F) {
            throw std::runtime_error(std::string("The package contains a file of an unsupported type: ") + e->fts_name);
        }
        removexattr(e->fts_path, "com.apple.quarantine", XATTR_NOFOLLOW);
        require(getxattr(e->fts_path, "com.apple.quarantine", nullptr, 0, 0, XATTR_NOFOLLOW) < 0, "The quarantine flag could not be removed from the package.");
    });
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

// The candidate must be validly signed (ad hoc is fine) and be the same product as the installed bundle: same bundle
// identifier and, when the installed one has a Team ID, a signature that chains to Apple with that Team ID.
void verifyIdentity(NSString *candidate, NSString *installed) {
    id code = staticCode(candidate);
    NSString *team = teamId(staticCode(installed));
    SecRequirementRef requirement = nullptr;
    if (team.length != 0) {
        // The Team ID field alone is not proof: an ad hoc signature can carry any string there. The requirement ties it to Apple's certificate chain.
        require([team rangeOfString:@"^[A-Z0-9]{10}$" options:NSRegularExpressionSearch].location != NSNotFound, "The installed component has an unusual Team ID.");
        NSString *text = [NSString stringWithFormat:@"anchor apple generic and certificate leaf[subject.OU] = \"%@\"", team];
        require(SecRequirementCreateWithString((__bridge CFStringRef)text, kSecCSDefaultFlags, &requirement) == errSecSuccess, "Could not build the signature requirement.");
    }
    id holder = CFBridgingRelease(requirement);
    OSStatus status = SecStaticCodeCheckValidity((__bridge SecStaticCodeRef)code,
        kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode, (__bridge SecRequirementRef)holder);
    if (status == errSecCSReqFailed) {
        throw std::runtime_error(std::string("The new version is signed by a different developer than the installed one (Team ID ") + team.UTF8String + ").");
    }
    if (status != errSecSuccess) {
        NSString *why = CFBridgingRelease(SecCopyErrorMessageString(status, nullptr));
        throw std::runtime_error(std::string("The code signature of the new version is not valid (") + (why ? why.UTF8String : "unknown error") + ").");
    }
    require([bundleId(candidate) isEqualToString:bundleId(installed)], "The new version has a different bundle identifier than the installed one.");
}

// Copies the installed bundle and its backup.json into the work folder; returns the folder that becomes the backup slot.
NSString *prepareBackup(Job const& job, std::string const& installedVersion, abort_callback& abort) {
    NSString *fresh = join(job.work, @"backup");
    makeDirectory(fresh);
    run({"/usr/bin/ditto", "--noqtn", job.installed().fileSystemRepresentation, join(fresh, ns(job.name + ".component")).fileSystemRepresentation}, abort,
        "Could not back up the installed version.");
    NSData *json = [NSJSONSerialization dataWithJSONObject:@{@"version": ns(installedVersion), @"saved": @((long long)time(nullptr))} options:0 error:nil];
    require([json writeToFile:join(fresh, @"backup.json") atomically:NO], "Could not back up the installed version.");
    return fresh;
}

// Replaces the single backup slot in one step.
void commitBackup(Job const& job, NSString *fresh) {
    NSString *slot = backupSlot(job.name);
    makeDirectory(slot.stringByDeletingLastPathComponent);
    if ([fm() fileExistsAtPath:slot]) {
        require([fm() replaceItemAtURL:[NSURL fileURLWithPath:slot] withItemAtURL:[NSURL fileURLWithPath:fresh] backupItemName:nil options:0
                      resultingItemURL:nil error:nil], "Could not replace the previous backup.");
    } else {
        require(rename(fresh.fileSystemRepresentation, slot.fileSystemRepresentation) == 0, "Could not store the backup.");
    }
}

// Fails when ditto extracted something the central directory (read by the layout check) does not list: the local
// headers can announce more than it does. Folders that listed paths pass through are fine.
void requireOnlyListed(NSString *dir, std::vector<std::string> const& listed) {
    NSMutableSet<NSString *> *allowed = [NSMutableSet set];
    for (auto const& entry : listed) {
        NSString *path = [ns(entry) precomposedStringWithCanonicalMapping];
        while ([path hasSuffix:@"/"]) path = [path substringToIndex:path.length - 1];
        for (; path.length != 0 && ![allowed containsObject:path]; path = path.stringByDeletingLastPathComponent) [allowed addObject:path];
    }
    size_t const skip = strlen(dir.fileSystemRepresentation) + 1;
    walkTree(dir, [&](FTSENT const *e) {
        if (e->fts_level == 0) return;
        NSString *path = [NSString stringWithUTF8String:e->fts_path + skip]; // nil when the name is not UTF-8: never listed
        if (![allowed containsObject:[path precomposedStringWithCanonicalMapping]]) {
            throw std::runtime_error(std::string("The package contains a file that is not in its own listing: ") + (e->fts_path + skip));
        }
    });
}

// Steps shared by install and restore: the new bundle already sits at job.staged(). The old backup is
// replaced only after the staging worked, and a failing backup swap takes the staging back.
void finish(Job const& job, std::string const& installedVersion, abort_callback& abort) {
    sanitize(job.staged());
    verifyIdentity(job.staged(), job.installed());
    NSString *fresh = prepareBackup(job, installedVersion, abort);

    // The folder moves into place in one rename, so foobar2000 never sees a half written pending/<name>.
    NSString *pending = join(userComponentsDir(), @"pending");
    makeDirectory(pending);
    // An uninstall marker (file) or an older staged folder moves aside, outside the work folder (which is wiped),
    // so a failure below can put it back and nothing deletes it unless the install worked.
    NSString *target = join(pending, ns(job.name)), *aside = join(rootDir(), ns("previous-pending-" + job.name));
    struct stat st;
    bool hadPending = lstat(target.fileSystemRepresentation, &st) == 0;
    if (hadPending) {
        if (lstat(aside.fileSystemRepresentation, &st) == 0) {
            throw std::runtime_error(std::string("An earlier pending entry was left at ") + aside.fileSystemRepresentation + "; move it away first.");
        }
        require(rename(target.fileSystemRepresentation, aside.fileSystemRepresentation) == 0, "Could not stage the new version.");
    }
    auto putBack = [&](char const *why) {
        if (hadPending && rename(aside.fileSystemRepresentation, target.fileSystemRepresentation) != 0) {
            throw std::runtime_error(std::string(why) + " The previous pending entry could not be put back and was left at " + aside.fileSystemRepresentation + ".");
        }
    };
    if (rename(job.staged().stringByDeletingLastPathComponent.fileSystemRepresentation, target.fileSystemRepresentation) != 0) {
        putBack("Could not stage the new version.");
        throw std::runtime_error("Could not stage the new version.");
    }
    try {
        commitBackup(job, fresh);
    } catch (...) {
        [fm() removeItemAtPath:target error:nil];
        putBack("Could not store the backup.");
        throw;
    }
    if (hadPending) [fm() removeItemAtPath:aside error:nil];
}

template <class F>
InstallOutcome guarded(F const& body) {
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
            throw std::runtime_error(std::string("The download failed: ") + e.what());
        }

        NSData *bytes = [NSData dataWithContentsOfFile:zip options:NSDataReadingMappedAlways error:nil];
        require(bytes != nil, "Could not read the download.");
        PackageCheck check = checkPackageLayout(std::string_view(static_cast<char const *>(bytes.bytes), bytes.length), name);
        if (!check.ok) throw std::runtime_error(check.error);

        NSString *extracted = join(job.work, @"x");
        // Without --norsrc and --noextattr ditto turns AppleDouble entries (__MACOSX/._x) into resource forks and attributes, which the
        // size watchdog does not see; as plain files they are counted. A bundle needs neither: its signature lives in files.
        run({"/usr/bin/ditto", "-x", "-k", "--noqtn", "--norsrc", "--noextattr", zip.fileSystemRepresentation, extracted.fileSystemRepresentation}, abort,
            "Could not extract the package.", extracted);
        requireOnlyListed(extracted, check.entries);
        // A zip can hold links: both levels must be real folders before anything is moved out of them.
        NSString *source = join(join(extracted, @"mac"), ns(name + ".component"));
        if (!isRealDirectory(join(extracted, @"mac")) || !isRealDirectory(source)) throw std::runtime_error("The package does not hold a plain mac/" + name + ".component folder.");
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
