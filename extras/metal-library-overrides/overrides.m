// MIT License; Copyright (c) 2026 Cyandev. See LICENSE in this directory.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <CommonCrypto/CommonDigest.h>
#import <objc/runtime.h>
#import <pthread.h>
#import <dispatch/dispatch.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>

// This optional diagnostic module never modifies the source library or App.
static const NSUInteger SRMaximumLibraryBytes = 16 * 1024 * 1024;
static pthread_mutex_t SRLock = PTHREAD_MUTEX_INITIALIZER;
static NSDictionary<NSString *, NSDictionary *> *SRMappings;
static BOOL SRInstalled;
static NSUInteger SRCalls, SRMatches, SRReplacements, SRPassthrough, SRLibraryErrors;
static NSDictionary *SRLastMatch, *SRLastLibraryError;
static NSDictionary *SRLastPreflight;
static NSString *SRConfigurationError;

typedef id __attribute__((ns_returns_retained)) (*SRNewLibraryFunction)(id, SEL, dispatch_data_t, NSError **);
static SRNewLibraryFunction SROriginalNewLibrary;

@interface SRMetalLibraryOverrides : NSObject
+ (NSDictionary *)configureWithManifest:(NSString *)path;
+ (NSDictionary *)status;
+ (NSDictionary *)disable;
@end

static NSString *SRSHA256(const void *bytes, NSUInteger size) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes, (CC_LONG)size, digest);
    char result[CC_SHA256_DIGEST_LENGTH * 2 + 1];
    const char *hex = "0123456789abcdef";
    for (NSUInteger i = 0; i < sizeof(digest); i++) {
        result[i * 2] = hex[digest[i] >> 4];
        result[i * 2 + 1] = hex[digest[i] & 15];
    }
    result[sizeof(result) - 1] = 0;
    return [NSString stringWithUTF8String:result];
}

static BOOL SRHashValid(id value) {
    if (![value isKindOfClass:NSString.class] || [value length] != 64) return NO;
    return [value rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location == NSNotFound;
}

static BOOL SRSizeValid(id value) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
    double number = [value doubleValue];
    return number >= 24 && number <= SRMaximumLibraryBytes && number == (double)[value unsignedLongLongValue];
}

static BOOL SRMetalLibraryValid(NSData *data) {
    if (data.length < 24 || data.length > SRMaximumLibraryBytes || memcmp(data.bytes, "MTLB", 4)) return NO;
    uint64_t declared = 0;
    memcpy(&declared, (const char *)data.bytes + 16, sizeof(declared));
    return CFSwapInt64LittleToHost(declared) == data.length;
}

static NSData *SRReadBoundedFile(NSString *path, NSUInteger limit) {
    int file = open(path.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
    if (file < 0) return nil;
    struct stat info;
    if (fstat(file, &info) || !S_ISREG(info.st_mode) || info.st_size < 0 || (uint64_t)info.st_size > limit) {
        close(file);
        return nil;
    }
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)info.st_size];
    size_t offset = 0;
    while (offset < data.length) {
        ssize_t count = read(file, (char *)data.mutableBytes + offset, data.length - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { close(file); return nil; }
        offset += (size_t)count;
    }
    char extra;
    ssize_t trailing;
    do { trailing = read(file, &extra, 1); } while (trailing < 0 && errno == EINTR);
    close(file);
    return trailing == 0 ? [data copy] : nil;
}

static NSDictionary *SRError(NSString *message) {
    pthread_mutex_lock(&SRLock);
    SRConfigurationError = message;
    pthread_mutex_unlock(&SRLock);
    return @{@"ok": @NO, @"schema": @1, @"error": message};
}

static NSDictionary *SRPreflight(NSData *data, id<MTLDevice> device) {
    __attribute__((objc_precise_lifetime)) dispatch_data_t buffer = dispatch_data_create(
        data.bytes, data.length, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ (void)data; });
    NSError *error = nil;
    // Avoid applying an older mapping to the replacement during reconfigure.
    pthread_mutex_lock(&SRLock);
    SRNewLibraryFunction original = SROriginalNewLibrary ?: (SRNewLibraryFunction)method_getImplementation(
        class_getInstanceMethod(NSClassFromString(@"MTLSimDevice"), @selector(newLibraryWithData:error:)));
    pthread_mutex_unlock(&SRLock);
    id<MTLLibrary> library = original(device, @selector(newLibraryWithData:error:), buffer, &error);
    if (!library) return @{@"ok": @NO, @"stage": @"library", @"domain": error.domain ?: @"", @"code": @(error.code)};
    NSArray<NSString *> *names = library.functionNames;
    if (!names.count || names.count > 32) return @{@"ok": @NO, @"stage": @"function_limit", @"functions": @(names.count)};
    NSMutableArray<id<MTLFunction>> *vertices = [NSMutableArray array], *fragments = [NSMutableArray array], *kernels = [NSMutableArray array];
    for (NSString *name in names) {
        id<MTLFunction> function = [library newFunctionWithName:name];
        if (!function || function.functionConstantsDictionary.count) return @{@"ok": @NO, @"stage": @"unsupported_function_constants"};
        switch (function.functionType) {
            case MTLFunctionTypeVertex: [vertices addObject:function]; break;
            case MTLFunctionTypeFragment: [fragments addObject:function]; break;
            case MTLFunctionTypeKernel: [kernels addObject:function]; break;
            default: return @{@"ok": @NO, @"stage": @"unsupported_function_type"};
        }
    }
    NSMutableIndexSet *coveredVertices = [NSMutableIndexSet indexSet], *coveredFragments = [NSMutableIndexSet indexSet];
    NSUInteger attempts = 0, successful = 0, computeSuccessful = 0, failures = 0;
    NSDictionary *lastError = nil;
    const MTLPixelFormat formats[] = {MTLPixelFormatBGRA8Unorm, MTLPixelFormatRGBA16Float};
    for (NSUInteger v = 0; v < vertices.count; v++) {
        for (NSUInteger f = 0; f < fragments.count; f++) {
            for (NSUInteger format = 0; format < sizeof(formats) / sizeof(formats[0]); format++) {
                MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
                descriptor.vertexFunction = vertices[v];
                descriptor.fragmentFunction = fragments[f];
                descriptor.colorAttachments[0].pixelFormat = formats[format];
                error = nil;
                attempts++;
                id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
                if (pipeline) {
                    successful++;
                    [coveredVertices addIndex:v];
                    [coveredFragments addIndex:f];
                    break;
                }
                failures++;
                if (error) lastError = @{@"domain": error.domain ?: @"", @"code": @(error.code)};
            }
        }
    }
    for (id<MTLFunction> kernel in kernels) {
        error = nil;
        attempts++;
        id<MTLComputePipelineState> pipeline = [device newComputePipelineStateWithFunction:kernel error:&error];
        if (pipeline) computeSuccessful++;
        else {
            failures++;
            if (error) lastError = @{@"domain": error.domain ?: @"", @"code": @(error.code)};
        }
    }
    BOOL ok = coveredVertices.count == vertices.count && coveredFragments.count == fragments.count && computeSuccessful == kernels.count;
    return @{@"ok": @(ok), @"stage": @"pipelines", @"functions": @(names.count),
             @"vertices": @(vertices.count), @"fragments": @(fragments.count), @"kernels": @(kernels.count),
             @"covered_vertices": @(coveredVertices.count), @"covered_fragments": @(coveredFragments.count),
             @"pipeline_attempts": @(attempts), @"render_successes": @(successful),
             @"compute_successes": @(computeSuccessful), @"pipeline_failures": @(failures),
             @"last_error": lastError ?: NSNull.null};
}

static id SRNewLibrary(id self, SEL selector, dispatch_data_t input, NSError **error) __attribute__((ns_returns_retained));
static id SRNewLibrary(id self, SEL selector, dispatch_data_t input, NSError **error) {
    // A strong snapshot survives a concurrent configure/disable. An in-flight
    // matched call may complete after disable; all later snapshots pass through.
    pthread_mutex_lock(&SRLock);
    SRCalls++;
    NSDictionary *mappings = SRMappings;
    pthread_mutex_unlock(&SRLock);
    NSDictionary *mapping = nil;
    NSString *inputHash = nil;
    size_t inputSize = input ? dispatch_data_get_size(input) : 0;
    if (mappings.count && inputSize <= SRMaximumLibraryBytes) {
        BOOL candidate = NO;
        for (NSDictionary *entry in mappings.allValues) {
            if ([entry[@"input_size"] unsignedLongLongValue] == inputSize) { candidate = YES; break; }
        }
        if (candidate) {
            const void *bytes = NULL;
            size_t mappedSize = 0;
            __attribute__((objc_precise_lifetime)) dispatch_data_t mapped = dispatch_data_create_map(input, &bytes, &mappedSize);
            if (mapped && mappedSize == inputSize) {
                inputHash = SRSHA256(bytes, mappedSize);
                mapping = mappings[[NSString stringWithFormat:@"%zu:%@", inputSize, inputHash]];
            }
            // mapped must remain alive until hashing has completed.
            (void)mapped;
        }
    }
    dispatch_data_t actual = input;
    if (mapping) {
        NSData *replacement = mapping[@"data"];
        actual = dispatch_data_create(replacement.bytes, replacement.length,
                                      dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ (void)replacement; });
        if (actual) {
            pthread_mutex_lock(&SRLock);
            SRMatches++;
            SRReplacements++;
            SRLastMatch = @{@"input_size": @(inputSize), @"input_sha256": inputHash,
                            @"output_size": mapping[@"output_size"], @"output_sha256": mapping[@"output_sha256"]};
            pthread_mutex_unlock(&SRLock);
        }
    }
    if (!mapping || !actual) {
        actual = input;
        pthread_mutex_lock(&SRLock);
        SRPassthrough++;
        pthread_mutex_unlock(&SRLock);
    }
    // Preserve NSError** semantics, including NULL, and new-family +1 ownership.
    // Do not create an error pointer or clear the caller's existing NSError.
    id library = SROriginalNewLibrary(self, selector, actual, error);
    if (!library && error && *error) {
        NSError *failure = *error;
        pthread_mutex_lock(&SRLock);
        SRLibraryErrors++;
        // Deliberately omit localizedDescription/userInfo: they can contain paths.
        SRLastLibraryError = @{@"domain": failure.domain ?: @"", @"code": @(failure.code)};
        pthread_mutex_unlock(&SRLock);
    }
    return library;
}

@implementation SRMetalLibraryOverrides
+ (NSDictionary *)configureWithManifest:(NSString *)path {
    @try {
        if (![path isKindOfClass:NSString.class] || !path.isAbsolutePath) return SRError(@"Manifest path must be absolute");
        NSError *error = nil;
        NSData *manifestData = SRReadBoundedFile(path, 1024 * 1024);
        if (!manifestData || manifestData.length > 1024 * 1024) return SRError(@"Cannot read bounded manifest");
        id manifest = [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:&error];
        if (![manifest isKindOfClass:NSDictionary.class] || ![manifest[@"schema"] isKindOfClass:NSNumber.class] ||
            CFGetTypeID((__bridge CFTypeRef)manifest[@"schema"]) == CFBooleanGetTypeID() || ![manifest[@"schema"] isEqual:@1] ||
            ![manifest[@"mappings"] isKindOfClass:NSArray.class]) return SRError(@"Expected schema=1 and mappings array");
        NSArray *entries = manifest[@"mappings"];
        if (!entries.count || entries.count > 16) return SRError(@"Expected 1 to 16 mappings");
        // Metal's lazy implementation classes may not exist at dylib startup.
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        Class target = NSClassFromString(@"MTLSimDevice");
        if (!target || !device || ![device isKindOfClass:target]) return SRError(@"Default Metal device is not MTLSimDevice");
        SEL selector = @selector(newLibraryWithData:error:);
        Method resolved = class_getInstanceMethod(target, selector);
        if (!resolved) return SRError(@"MTLSimDevice newLibraryWithData:error: unavailable");
        NSMutableDictionary *validated = [NSMutableDictionary dictionary];
        for (id entry in entries) {
            if (![entry isKindOfClass:NSDictionary.class] || !SRHashValid(entry[@"input_sha256"]) ||
                !SRHashValid(entry[@"output_sha256"]) || !SRSizeValid(entry[@"input_size"]) ||
                !SRSizeValid(entry[@"output_size"]) || ![entry[@"output_path"] isKindOfClass:NSString.class] ||
                ![entry[@"output_path"] isAbsolutePath]) return SRError(@"Invalid mapping hash, size, or output path");
            NSData *replacement = SRReadBoundedFile(entry[@"output_path"], SRMaximumLibraryBytes);
            if (!replacement || replacement.length != [entry[@"output_size"] unsignedLongLongValue] ||
                !SRMetalLibraryValid(replacement) || ![SRSHA256(replacement.bytes, replacement.length) isEqual:entry[@"output_sha256"]])
                return SRError(@"Replacement does not match validated size, MTLB header, and SHA256");
            NSDictionary *preflight = SRPreflight(replacement, device);
            pthread_mutex_lock(&SRLock);
            SRLastPreflight = preflight;
            pthread_mutex_unlock(&SRLock);
            if (![preflight[@"ok"] boolValue]) return SRError(@"Replacement failed simulator compiler preflight");
            NSString *key = [NSString stringWithFormat:@"%@:%@", entry[@"input_size"], entry[@"input_sha256"]];
            if (validated[key]) return SRError(@"Duplicate input mapping");
            validated[key] = @{@"input_size": entry[@"input_size"], @"input_sha256": entry[@"input_sha256"],
                               @"output_size": entry[@"output_size"], @"output_sha256": entry[@"output_sha256"],
                               @"data": replacement, @"preflight": preflight};
        }
        pthread_mutex_lock(&SRLock);
        if (!SRInstalled) {
            SROriginalNewLibrary = (SRNewLibraryFunction)method_getImplementation(resolved);
            // Add to this concrete class when the implementation is inherited;
            // never replace a superclass method shared by other Metal devices.
            if (!class_addMethod(target, selector, (IMP)SRNewLibrary, method_getTypeEncoding(resolved)))
                method_setImplementation(class_getInstanceMethod(target, selector), (IMP)SRNewLibrary);
            SRInstalled = YES;
        }
        SRMappings = [validated copy];
        SRConfigurationError = nil;
        pthread_mutex_unlock(&SRLock);
        return [self status];
    } @catch (__unused NSException *exception) {
        return SRError(@"Exception while validating manifest; prior configuration retained");
    }
}

+ (NSDictionary *)status {
    pthread_mutex_lock(&SRLock);
    NSMutableDictionary *result = [@{@"schema": @1, @"ok": @YES, @"installed": @(SRInstalled),
        @"enabled": @(SRMappings.count > 0), @"mapping_count": @(SRMappings.count),
        @"calls": @(SRCalls), @"matches": @(SRMatches), @"replacements": @(SRReplacements),
        @"passthrough": @(SRPassthrough), @"library_errors": @(SRLibraryErrors),
        @"last_match": SRLastMatch ?: NSNull.null, @"last_library_error": SRLastLibraryError ?: NSNull.null,
        @"configuration_error": SRConfigurationError ?: NSNull.null,
        @"last_preflight": SRLastPreflight ?: NSNull.null,
        @"pipeline_errors": @{@"observed": @NO, @"reason": @"Library-only hook; sample pipeline API externally"}} mutableCopy];
    pthread_mutex_unlock(&SRLock);
    return result;
}

+ (NSDictionary *)disable {
    pthread_mutex_lock(&SRLock);
    SRMappings = nil;
    SRConfigurationError = nil;
    pthread_mutex_unlock(&SRLock);
    return [self status];
}
@end

__attribute__((constructor)) static void SRConfigureFromEnvironment(void) {
    @autoreleasepool {
        const char *path = getenv("SIMRUN_METAL_LIBRARY_MAP");
        if (path && *path) [SRMetalLibraryOverrides configureWithManifest:[NSString stringWithUTF8String:path]];
    }
}
