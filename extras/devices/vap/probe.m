#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>

static NSDictionary *gResult;
@interface QGMP4FrameHWDecoder : NSObject
+ (OSStatus)createSessionWithFormat:(CMFormatDescriptionRef)format attributes:(CFDictionaryRef)attributes session:(VTDecompressionSessionRef *)session;
@end
@implementation QGMP4FrameHWDecoder
+ (OSStatus)createSessionWithFormat:(CMFormatDescriptionRef)format attributes:(CFDictionaryRef)attributes session:(VTDecompressionSessionRef *)session {
  return VTDecompressionSessionCreate(kCFAllocatorDefault,format,NULL,attributes,NULL,session);
}
@end
static void runProbe(void) {
  NSMutableDictionary *result = [@{@"complete": @NO, @"frames": @0} mutableCopy];
  gResult = result;
  @autoreleasepool {
    NSString *path = [NSBundle.mainBundle pathForResource:@"sample" ofType:@"h264"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    const uint8_t *bytes = data.bytes;
    NSMutableArray<NSData *> *nals = [NSMutableArray new];
    NSUInteger start = NSNotFound;
    for (NSUInteger i=0; i+3<data.length; i++) {
      NSUInteger prefix = bytes[i]==0 && bytes[i+1]==0 && bytes[i+2]==1 ? 3 :
        (i+4<data.length && bytes[i]==0 && bytes[i+1]==0 && bytes[i+2]==0 && bytes[i+3]==1 ? 4 : 0);
      if (!prefix) continue;
      if (start != NSNotFound) [nals addObject:[data subdataWithRange:NSMakeRange(start,i-start)]];
      start = i+prefix; i += prefix-1;
    }
    if (start != NSNotFound) [nals addObject:[data subdataWithRange:NSMakeRange(start,data.length-start)]];
    NSData *sps, *pps;
    for (NSData *nal in nals) {
      unsigned type = ((const uint8_t *)nal.bytes)[0]&31;
      if (type==7) sps=nal; if(type==8) pps=nal;
    }
    const uint8_t *parameters[] = {sps.bytes,pps.bytes}; size_t lengths[] = {sps.length,pps.length};
    CMVideoFormatDescriptionRef decoderFormat = NULL;
    OSStatus formatStatus = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault,2,parameters,lengths,4,&decoderFormat);
    result[@"formatStatus"]=@(formatStatus); result[@"nalCount"]=@(nals.count);
    if (formatStatus) { result[@"complete"]=@YES; return; }
    VTDecompressionSessionRef session = NULL;
    NSUInteger frames = 0;
    for (NSData *nal in nals) {
      unsigned type = ((const uint8_t *)nal.bytes)[0]&31;
      if (type!=1 && type!=5) continue;
      if (!session) {
        NSDictionary *attrs = @{
          (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
          (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{}
        };
        CFDictionaryRef rawAttrs = NULL;
        BOOL typed = [NSProcessInfo.processInfo.arguments containsObject:@"--typed-callbacks"];
        if (typed || [NSProcessInfo.processInfo.arguments containsObject:@"--vap-callbacks"]) {
          uint32_t pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
          CFDictionaryRef surface = CFDictionaryCreate(NULL,NULL,NULL,0,
            typed ? &kCFTypeDictionaryKeyCallBacks : NULL,
            typed ? &kCFTypeDictionaryValueCallBacks : NULL);
          CFNumberRef number = CFNumberCreate(NULL,kCFNumberSInt32Type,&pixelFormat);
          const void *keys[] = {kCVPixelBufferIOSurfacePropertiesKey,kCVPixelBufferPixelFormatTypeKey};
          const void *values[] = {surface,number};
          rawAttrs = CFDictionaryCreate(NULL,keys,values,2,
            typed ? &kCFTypeDictionaryKeyCallBacks : NULL,
            typed ? &kCFTypeDictionaryValueCallBacks : NULL);
          // Deliberately match the app's observed ownership (including leaked child refs).
          fprintf(stderr,"VAP_ATTRIBUTES typed=%d surface=%p outer=%p\n",typed,surface,rawAttrs);
        }
        OSStatus status = [QGMP4FrameHWDecoder createSessionWithFormat:decoderFormat
          attributes:rawAttrs ?: (__bridge CFDictionaryRef)attrs session:&session];
        if (rawAttrs) CFRelease(rawAttrs);
        result[@"sessionStatus"] = @(status);
        if (status) break;
      }
      uint32_t length = htonl((uint32_t)nal.length);
      NSMutableData *packet = [NSMutableData dataWithBytes:&length length:4]; [packet appendData:nal];
      CMBlockBufferRef block = NULL; CMSampleBufferRef sample = NULL;
      CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault,NULL,packet.length,kCFAllocatorDefault,NULL,0,packet.length,0,&block);
      CMBlockBufferReplaceDataBytes(packet.bytes,block,0,packet.length);
      size_t packetSize=packet.length;
      CMSampleBufferCreateReady(kCFAllocatorDefault,block,decoderFormat,1,0,NULL,1,&packetSize,&sample);
      CFRelease(block);
      OSStatus status = VTDecompressionSessionDecodeFrameWithOutputHandler(session, sample, 0, NULL,
        ^(OSStatus st, VTDecodeInfoFlags flags, CVImageBufferRef image, CMTime pts, CMTime duration) {
          if (image) {
            result[@"frames"] = @([result[@"frames"] unsignedIntegerValue] + 1);
            result[@"width"] = @(CVPixelBufferGetWidth(image));
            result[@"height"] = @(CVPixelBufferGetHeight(image));
          }
          result[@"callbackStatus"] = @(st);
        });
      CFRelease(sample); frames++;
      result[@"decodeStatus"] = @(status); result[@"submitted"] = @(frames);
      if (status) break;
    }
    if (session) {
      VTDecompressionSessionWaitForAsynchronousFrames(session);
      VTDecompressionSessionInvalidate(session); CFRelease(session);
    }
    CFRelease(decoderFormat); result[@"complete"] = @YES;
  }
  NSString *json = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:result options:0 error:NULL] encoding:NSUTF8StringEncoding];
  fprintf(stderr, "VAP_PROBE %s\n", json.UTF8String);
}
@interface SRDecodeProbe : NSObject
+ (NSDictionary *)result;
@end
@implementation SRDecodeProbe
+ (NSDictionary *)result { return gResult ?: @{}; }
@end
@interface ProbeScene : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@end
@implementation ProbeScene
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
  self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
  self.window.rootViewController = [UIViewController new]; [self.window makeKeyAndVisible];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
    NSUInteger repeats = [NSProcessInfo.processInfo.arguments containsObject:@"--stress"] ? 100 : 1;
    NSUInteger passed = 0;
    for (NSUInteger i=0; i<repeats; i++) {
      @autoreleasepool { runProbe(); }
      if ([gResult[@"frames"] unsignedIntegerValue] == 45 && [gResult[@"complete"] boolValue]) passed++;
    }
    gResult = [gResult mutableCopy];
    [(NSMutableDictionary *)gResult setObject:@(passed) forKey:@"passedRuns"];
    [(NSMutableDictionary *)gResult setObject:@(repeats) forKey:@"runs"];
    fprintf(stderr,"VAP_STRESS passed=%lu runs=%lu\n",(unsigned long)passed,(unsigned long)repeats);
  });
}
@end
@interface ProbeApp : UIResponder <UIApplicationDelegate> @end
@implementation ProbeApp
- (UISceneConfiguration *)application:(UIApplication *)app configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
  UISceneConfiguration *config = [UISceneConfiguration configurationWithName:@"Probe" sessionRole:session.role];
  config.delegateClass = ProbeScene.class; return config;
}
@end
int main(int argc, char **argv) { @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(ProbeApp.class)); } }
