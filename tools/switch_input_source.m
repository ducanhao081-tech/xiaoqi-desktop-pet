#import <Carbon/Carbon.h>
#import <CoreFoundation/CoreFoundation.h>
#import <stdio.h>

static const char *cfstr(CFStringRef string) {
    static char buffer[1024];
    if (!string) {
        return "";
    }
    if (!CFStringGetCString(string, buffer, sizeof(buffer), kCFStringEncodingUTF8)) {
        return "";
    }
    return buffer;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <input-source-id-fragment>\n", argv[0]);
        return 2;
    }

    CFStringRef query = CFStringCreateWithCString(NULL, argv[1], kCFStringEncodingUTF8);
    CFArrayRef sources = TISCreateInputSourceList(NULL, false);
    if (!sources) {
        CFRelease(query);
        return 1;
    }

    CFIndex count = CFArrayGetCount(sources);
    for (CFIndex i = 0; i < count; i++) {
        TISInputSourceRef source = (TISInputSourceRef)CFArrayGetValueAtIndex(sources, i);
        CFStringRef sourceID = TISGetInputSourceProperty(source, kTISPropertyInputSourceID);
        CFStringRef name = TISGetInputSourceProperty(source, kTISPropertyLocalizedName);
        if (!sourceID) {
            continue;
        }
        if (CFStringFind(sourceID, query, 0).location != kCFNotFound) {
            OSStatus status = TISSelectInputSource(source);
            printf("%s\t%s\tstatus=%d\n", cfstr(sourceID), cfstr(name), (int)status);
            CFRelease(sources);
            CFRelease(query);
            return status == noErr ? 0 : 1;
        }
    }

    fprintf(stderr, "No input source matching %s\n", argv[1]);
    CFRelease(sources);
    CFRelease(query);
    return 1;
}
