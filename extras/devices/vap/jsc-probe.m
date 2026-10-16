#import <UIKit/UIKit.h>
#import <JavaScriptCore/JavaScriptCore.h>
#include <stdatomic.h>
#include <pthread.h>

static _Atomic(int) gPassed, gFailed, gActive, gPeak;
static JSContext *gMainContext;
static NSDictionary *gSummary;

static void runWorker(NSUInteger worker) {
  int active = atomic_fetch_add(&gActive,1)+1;
  int peak = atomic_load(&gPeak);
  while (active > peak && !atomic_compare_exchange_weak(&gPeak,&peak,active)) {}
  uint64_t threadID = 0; pthread_threadid_np(NULL,&threadID);
  for (NSUInteger i=0; i<100; i++) {
    @autoreleasepool {
      JSVirtualMachine *vm = [JSVirtualMachine new];
      JSContext *context = [[JSContext alloc] initWithVirtualMachine:vm];
      JSValue *value = [context evaluateScript:@"Array.from({length:64}, (_,i)=>i).reduce((a,b)=>a+b,0)"];
      if (context.exception || value.toInt32 != 2016) atomic_fetch_add(&gFailed,1);
      else atomic_fetch_add(&gPassed,1);
    }
  }
  atomic_fetch_sub(&gActive,1);
  fprintf(stderr,"JSC_WORKER worker=%lu thread=%llu finished\n",(unsigned long)worker,(unsigned long long)threadID);
}

@interface SRJSCProbe : NSObject
+ (NSDictionary *)result;
@end
@implementation SRJSCProbe
+ (NSDictionary *)result { return gSummary ?: @{@"complete":@NO,@"passed":@(atomic_load(&gPassed)),@"failed":@(atomic_load(&gFailed))}; }
@end

@interface JSCProbeScene : UIResponder <UIWindowSceneDelegate>
@property (nonatomic,strong) UIWindow *window;
@end
@implementation JSCProbeScene
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
  self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
  self.window.rootViewController = [UIViewController new]; [self.window makeKeyAndVisible];
  BOOL parallel = [NSProcessInfo.processInfo.arguments containsObject:@"--parallel"];
  fprintf(stderr,"JSC_READY mode=%s delay=3\n",parallel?"parallel":"serial");
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC),dispatch_get_main_queue(),^{
    gMainContext = [JSContext new];
    [gMainContext evaluateScript:@"globalThis.probeMain = 27"];
    fprintf(stderr,"JSC_START mode=%s\n",parallel?"parallel":"serial");
    double start = NSProcessInfo.processInfo.systemUptime;
    dispatch_group_t group = dispatch_group_create();
    NSUInteger workers = parallel ? 4 : 1;
    for (NSUInteger worker=0; worker<workers; worker++) {
      dispatch_group_async(group,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{runWorker(worker);});
    }
    dispatch_group_notify(group,dispatch_get_main_queue(),^{
      gSummary = @{@"complete":@YES,@"workers":@(workers),@"iterationsPerWorker":@100,
        @"passed":@(atomic_load(&gPassed)),@"failed":@(atomic_load(&gFailed)),
        @"peakWorkers":@(atomic_load(&gPeak)),
        @"mainResult":@([gMainContext evaluateScript:@"probeMain+15"].toInt32),
        @"seconds":@(NSProcessInfo.processInfo.systemUptime-start)};
      NSData *json = [NSJSONSerialization dataWithJSONObject:gSummary options:0 error:NULL];
      fprintf(stderr,"JSC_RESULT %s\n",[[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] UTF8String]);
    });
  });
}
@end
@interface JSCProbeApp : UIResponder <UIApplicationDelegate> @end
@implementation JSCProbeApp
- (UISceneConfiguration *)application:(UIApplication *)app configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
  UISceneConfiguration *config = [UISceneConfiguration configurationWithName:@"Probe" sessionRole:session.role];
  config.delegateClass = JSCProbeScene.class; return config;
}
@end
int main(int argc,char **argv) { @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(JSCProbeApp.class)); } }
