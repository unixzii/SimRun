// MIT License; Copyright (c) 2026 Cyandev. See LICENSE in this directory.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <unistd.h>
#import <sys/stat.h>

@protocol SROverrides
+ (NSDictionary *)status;
+ (NSDictionary *)configureWithManifest:(NSString *)path;
+ (NSDictionary *)disable;
@end

static NSMutableArray *checks;
static void Check(NSString *name, BOOL passed, id details) {
    [checks addObject:@{@"name": name, @"passed": @(passed), @"details": details ?: NSNull.null}];
}
static NSDictionary *Compile(NSData *bytes, id<MTLDevice> device) {
    dispatch_data_t data = dispatch_data_create(bytes.bytes, bytes.length,
        dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ (void)bytes; });
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithData:data error:&error];
    NSMutableArray *vertices = [NSMutableArray new], *fragments = [NSMutableArray new];
    for (NSString *name in library.functionNames) {
        id<MTLFunction> f = [library newFunctionWithName:name];
        if (f.functionType == MTLFunctionTypeVertex) [vertices addObject:f];
        if (f.functionType == MTLFunctionTypeFragment) [fragments addObject:f];
    }
    NSUInteger succeeded = 0, failed = 0, platformErrors = 0;
    for (id<MTLFunction> v in vertices) for (id<MTLFunction> f in fragments) {
        MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
        desc.vertexFunction = v; desc.fragmentFunction = f;
        desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        NSError *failure = nil;
        id<MTLRenderPipelineState> state = [device newRenderPipelineStateWithDescriptor:desc error:&failure];
        if (state) succeeded++; else failed++;
        if ([failure.localizedDescription containsString:@"not compiled for the simulator"]) platformErrors++;
    }
    return @{@"loaded": @(library != nil), @"function_count": @(library.functionNames.count),
        @"succeeded": @(succeeded), @"failed": @(failed), @"platform_errors": @(platformErrors),
        @"library_error_domain": error.domain ?: @"", @"library_error_code": @(error.code)};
}
static NSString *SaveManifest(NSDictionary *manifest, NSString *directory, NSString *name) {
    NSString *path = [directory stringByAppendingPathComponent:[name stringByAppendingString:@".json"]];
    NSData *bytes = [NSJSONSerialization dataWithJSONObject:manifest options:0 error:nil];
    if (![bytes writeToFile:path options:NSDataWritingAtomic error:nil]) return nil;
    chmod(path.fileSystemRepresentation, 0600);
    return path;
}
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 5) return 2;
        checks = [NSMutableArray new];
        Class<SROverrides> module = (Class<SROverrides>)NSClassFromString(@"SRMetalLibraryOverrides");
        if (!module) return 3;
        NSString *manifestPath = @(argv[3]), *directory = @(argv[4]);
        NSDictionary *startup = [module status];
        Check(@"startup_environment_configured_before_main", [startup[@"enabled"] boolValue] &&
              [startup[@"installed"] boolValue] && [startup[@"mapping_count"] integerValue] == 1, startup);
        NSData *original = [NSData dataWithContentsOfFile:@(argv[1])];
        NSData *simulator = [NSData dataWithContentsOfFile:@(argv[2])];
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        Check(@"simulator_device", [NSStringFromClass([device class]) isEqual:@"MTLSimDevice"], NSStringFromClass([device class]));
        NSDictionary *before = [module status], *compiled = Compile(original, device), *after = [module status];
        Check(@"exact_input_replaced_and_compiles", [compiled[@"succeeded"] integerValue] > 0 &&
              [compiled[@"platform_errors"] integerValue] == 0 &&
              [after[@"matches"] integerValue] == [before[@"matches"] integerValue] + 1, compiled);
        before = after; compiled = Compile(simulator, device); after = [module status];
        Check(@"simulator_input_unmatched_passthrough", [compiled[@"succeeded"] integerValue] > 0 &&
              [after[@"matches"] isEqual:before[@"matches"]] &&
              [after[@"passthrough"] integerValue] == [before[@"passthrough"] integerValue] + 1, compiled);
        [module disable]; before = [module status]; compiled = Compile(original, device); after = [module status];
        Check(@"disable_restores_original_platform_failure", ![after[@"enabled"] boolValue] &&
              [compiled[@"succeeded"] integerValue] == 0 && [compiled[@"platform_errors"] integerValue] > 0 &&
              [after[@"matches"] isEqual:before[@"matches"]], compiled);
        NSDictionary *configured = [module configureWithManifest:manifestPath]; compiled = Compile(original, device);
        Check(@"reenable_restores_success", [configured[@"enabled"] boolValue] && [compiled[@"succeeded"] integerValue] > 0, compiled);
        NSDictionary *valid = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:manifestPath] options:0 error:nil];
        NSArray *badNames = @[@"wrong_output_hash", @"wrong_output_size", @"device_output_exact_hash", @"schema_boolean", @"schema_unknown"];
        for (NSString *name in badNames) {
            NSMutableDictionary *manifest = [valid mutableCopy];
            NSMutableDictionary *entry = [valid[@"mappings"][0] mutableCopy];
            if ([name isEqual:@"wrong_output_hash"]) entry[@"output_sha256"] = [@"0" stringByPaddingToLength:64 withString:@"0" startingAtIndex:0];
            if ([name isEqual:@"wrong_output_size"]) entry[@"output_size"] = @([entry[@"output_size"] unsignedIntegerValue] + 1);
            if ([name isEqual:@"device_output_exact_hash"]) {
                entry[@"output_path"] = @(argv[1]); entry[@"output_sha256"] = entry[@"input_sha256"];
                entry[@"output_size"] = entry[@"input_size"];
            }
            if ([name isEqual:@"schema_boolean"]) manifest[@"schema"] = @YES;
            if ([name isEqual:@"schema_unknown"]) manifest[@"schema"] = @99;
            manifest[@"mappings"] = @[entry];
            NSString *path = SaveManifest(manifest, directory, name);
            NSDictionary *rejected = [module configureWithManifest:path];
            NSDictionary *retained = [module status];
            compiled = Compile(original, device);
            Check([name stringByAppendingString:@"_rejected_preserves_previous_mapping"], ![rejected[@"ok"] boolValue] &&
                  [retained[@"enabled"] boolValue] && [retained[@"mapping_count"] integerValue] == 1 &&
                  [compiled[@"succeeded"] integerValue] > 0, @{@"configuration": rejected, @"compile": compiled,
                  @"last_preflight": retained[@"last_preflight"] ?: NSNull.null});
        }
        for (NSString *name in @[@"unknown_input_hash", @"unknown_input_size"]) {
            NSMutableData *unknown = [original mutableCopy];
            if ([name isEqual:@"unknown_input_hash"]) ((uint8_t *)unknown.mutableBytes)[unknown.length - 1] ^= 1;
            else [unknown increaseLengthBy:1];
            before = [module status];
            dispatch_data_t bytes = dispatch_data_create(unknown.bytes, unknown.length,
                dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ (void)unknown; });
            NSError *error = nil;
            __unused id library = [device newLibraryWithData:bytes error:&error];
            after = [module status];
            Check(name, [after[@"matches"] isEqual:before[@"matches"]] &&
                  [after[@"passthrough"] integerValue] == [before[@"passthrough"] integerValue] + 1,
                  @{@"matches_delta": @([after[@"matches"] integerValue] - [before[@"matches"] integerValue]),
                    @"passthrough_delta": @([after[@"passthrough"] integerValue] - [before[@"passthrough"] integerValue])});
        }
        NSUInteger failures = 0;
        for (NSDictionary *check in checks) if (![check[@"passed"] boolValue]) failures++;
        NSDictionary *result = @{@"schema": @1, @"pid": @(getpid()), @"checks": checks,
            @"passed": @(failures == 0), @"failed_count": @(failures), @"status": [module status]};
        NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];
        puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
        return failures ? 1 : 0;
    }
}
