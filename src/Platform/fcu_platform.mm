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

bool readBundleUpdateSource(std::string const& fileName, std::string& json) {
    if (fileName.empty() || fileName[0] == '.' || fileName.find('/') != std::string::npos) return false;
    @autoreleasepool {
        // get_my_full_path() is <profile>/user-components/<name>/<name>.component on Mac.
        NSString *mine = [NSString stringWithUTF8String:core_api::get_my_full_path()];
        NSString *userComponents = mine.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
        NSString *name = [NSString stringWithUTF8String:fileName.c_str()];
        NSString *plist = [[[[userComponents stringByAppendingPathComponent:name]
            stringByAppendingPathComponent:[name stringByAppendingString:@".component"]]
            stringByAppendingPathComponent:@"Contents"] stringByAppendingPathComponent:@"Info.plist"];

        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plist];
        id value = info[@"FB2KUpdateSource"];
        if (!value) return false;
        if (![value isKindOfClass:[NSDictionary class]] || ![NSJSONSerialization isValidJSONObject:value]) {
            json = "null";
            return true;
        }
        NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
        json = data ? std::string(static_cast<const char *>(data.bytes), data.length) : "null";
        return true;
    }
}

} // namespace fcu
