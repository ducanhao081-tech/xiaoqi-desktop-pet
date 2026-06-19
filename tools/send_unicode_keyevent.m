#import <ApplicationServices/ApplicationServices.h>
#import <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static UniChar *utf8_to_unichars(const char *text, CFIndex *length) {
    CFStringRef str = CFStringCreateWithCString(NULL, text, kCFStringEncodingUTF8);
    if (!str) {
        return NULL;
    }
    *length = CFStringGetLength(str);
    UniChar *chars = calloc((size_t)*length, sizeof(UniChar));
    if (!chars) {
        CFRelease(str);
        return NULL;
    }
    CFStringGetCharacters(str, CFRangeMake(0, *length), chars);
    CFRelease(str);
    return chars;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <utf8 text>\n", argv[0]);
        return 2;
    }

    CFIndex length = 0;
    UniChar *chars = utf8_to_unichars(argv[1], &length);
    if (!chars || length <= 0) {
        fprintf(stderr, "Could not convert input text\n");
        free(chars);
        return 1;
    }

    for (CFIndex i = 0; i < length; i++) {
        CGEventRef down = CGEventCreateKeyboardEvent(NULL, 0, true);
        CGEventKeyboardSetUnicodeString(down, 1, &chars[i]);
        CGEventPost(kCGHIDEventTap, down);
        CFRelease(down);

        CGEventRef up = CGEventCreateKeyboardEvent(NULL, 0, false);
        CGEventKeyboardSetUnicodeString(up, 1, &chars[i]);
        CGEventPost(kCGHIDEventTap, up);
        CFRelease(up);
        usleep(12000);
    }

    free(chars);
    return 0;
}
