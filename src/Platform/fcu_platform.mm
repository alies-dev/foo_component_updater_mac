#include "fcu_platform.h"

#include "../fb2k_sdk.h"

@interface FCUBundleAnchor : NSObject
@end
@implementation FCUBundleAnchor
@end

namespace fcu {

std::string bundledResource(char const* name, char const* ext) {
    @autoreleasepool {
        NSBundle *bundle = [NSBundle bundleForClass:[FCUBundleAnchor class]];
        NSString *path = [bundle pathForResource:[NSString stringWithUTF8String:name]
                                          ofType:[NSString stringWithUTF8String:ext]];
        NSData *data = path ? [NSData dataWithContentsOfFile:path] : nil;
        if (!data) return std::string();
        return std::string(static_cast<const char *>(data.bytes), data.length);
    }
}

std::map<std::string, std::string> readBundleDictionaries(std::string const& fileName, std::vector<char const *> const& keys) {
    std::map<std::string, std::string> found;
    if (fileName.empty() || fileName[0] == '.' || fileName.find('/') != std::string::npos) return found;
    @autoreleasepool {
        // get_my_full_path() is <profile>/user-components/<name>/<name>.component on Mac.
        NSString *mine = [NSString stringWithUTF8String:core_api::get_my_full_path()];
        NSString *userComponents = mine.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
        NSString *name = [NSString stringWithUTF8String:fileName.c_str()];
        NSString *plist = [[[[userComponents stringByAppendingPathComponent:name]
            stringByAppendingPathComponent:[name stringByAppendingString:@".component"]]
            stringByAppendingPathComponent:@"Contents"] stringByAppendingPathComponent:@"Info.plist"];

        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plist];
        for (char const *key : keys) {
            id value = info[[NSString stringWithUTF8String:key]];
            if (!value) continue;
            NSData *data = [value isKindOfClass:[NSDictionary class]] && [NSJSONSerialization isValidJSONObject:value]
                ? [NSJSONSerialization dataWithJSONObject:value options:0 error:nil] : nil;
            found[key] = data ? std::string(static_cast<const char *>(data.bytes), data.length) : "null";
        }
    }
    return found;
}

} // namespace fcu
