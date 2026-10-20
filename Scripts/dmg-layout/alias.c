// Finder's background images still use Carbon aliases. Keep this legacy
// on-disk metadata bridge out of the application and use no Finder automation.
#include <CoreServices/CoreServices.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void check(OSStatus status, const char *operation) {
    if (status != noErr) {
        fprintf(stderr, "%s failed: %d\n", operation, (int)status);
        exit(1);
    }
}

static FSRef file_ref(const char *path) {
    FSRef ref;
    check(FSPathMakeRef((const UInt8 *)path, &ref, NULL), "FSPathMakeRef");
    return ref;
}

int main(int argc, char **argv) {
    if (argc < 3) return 2;
    if (strcmp(argv[1], "create") == 0 && argc == 4) {
        FSRef target = file_ref(argv[2]);
        AliasHandle alias = NULL;
        check(FSNewAlias(NULL, &target, &alias), "FSNewAlias");
        Size length = GetHandleSize((Handle)alias);
        FILE *output = fopen(argv[3], "wb");
        if (!output || fwrite(*alias, 1, length, output) != (size_t)length) return 1;
        fclose(output);
        DisposeHandle((Handle)alias);
        return 0;
    }
    if (strcmp(argv[1], "resolve") == 0 && argc == 4) {
        FILE *input = fopen(argv[2], "rb");
        if (!input) return 1;
        fseek(input, 0, SEEK_END);
        long length = ftell(input);
        rewind(input);
        if (length <= 0 || length > 65535) return 1;
        UInt8 *bytes = malloc((size_t)length);
        if (!bytes || fread(bytes, 1, length, input) != (size_t)length) return 1;
        fclose(input);
        CFDataRef alias = CFDataCreate(kCFAllocatorDefault, bytes, length);
        free(bytes);
        CFDataRef bookmark = CFURLCreateBookmarkDataFromAliasRecord(kCFAllocatorDefault, alias);
        if (!bookmark) return 1;
        Boolean stale = false;
        CFErrorRef error = NULL;
        CFURLRef target = CFURLCreateByResolvingBookmarkData(
            kCFAllocatorDefault, bookmark,
            kCFURLBookmarkResolutionWithoutUIMask | kCFURLBookmarkResolutionWithoutMountingMask,
            NULL, NULL, &stale, &error
        );
        if (!target) {
            fprintf(stderr, "The background alias cannot resolve after remount\n");
            return 1;
        }
        UInt8 path[PATH_MAX];
        char actual[PATH_MAX], expected[PATH_MAX];
        if (!CFURLGetFileSystemRepresentation(target, true, path, sizeof(path))
            || !realpath((const char *)path, actual) || !realpath(argv[3], expected)
            || strcmp(actual, expected) != 0) {
            fprintf(stderr, "The background alias points outside this image\n");
            return 1;
        }
        CFRelease(target);
        CFRelease(bookmark);
        CFRelease(alias);
        puts("PASS background alias resolves after remount");
        return 0;
    }
    fprintf(stderr, "usage: alias create <image> <output> | resolve <alias-data> <expected-image>\n");
    return 2;
}
