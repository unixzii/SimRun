// FocusProbe — deterministic keyboard/AX ownership fixture. Covered by root MIT license.
#import <UIKit/UIKit.h>

@interface NSObject (FocusProbePrivate)
+ (id)activeInstance;
- (id)inputDelegate;
- (id)firstResponder;
@end
static NSArray<UITextField *> *gFields;
static UIWindow *gWindow;
static BOOL gHopAfterFirstCharacter;
static NSInteger gCallbackMode;
@interface FocusInputDelegate : NSObject <UITextInputDelegate>
@property(nonatomic,weak)id<UITextInputDelegate> original;
- (void)conversationContext:(UIConversationContext *)context didChange:(id<UITextInput>)input API_AVAILABLE(ios(18.4));
@end
static FocusInputDelegate *gInputDelegate;
@implementation FocusInputDelegate
- (void)selectionWillChange:(id<UITextInput>)input { [self.original selectionWillChange:input]; }
- (void)selectionDidChange:(id<UITextInput>)input { [self.original selectionDidChange:input]; }
- (void)textWillChange:(id<UITextInput>)input {
  if(gCallbackMode==4){gCallbackMode=0;[gFields[1] becomeFirstResponder];}
  [self.original textWillChange:input];
}
- (void)textDidChange:(id<UITextInput>)input { [self.original textDidChange:input]; }
- (void)conversationContext:(UIConversationContext *)context didChange:(id<UITextInput>)input {
  if (@available(iOS 18.4,*)) if([self.original respondsToSelector:_cmd])[self.original conversationContext:context didChange:input];
}
@end
static NSString *Identity(id object) {
  if (!object) return @"none";
  for (NSUInteger i=0;i<gFields.count;i++) if (gFields[i]==object) return [NSString stringWithFormat:@"field%lu",(unsigned long)i];
  return NSStringFromClass([object class]);
}
@interface FocusProbe : NSObject
+ (BOOL)focus:(NSInteger)index;
+ (NSDictionary *)state;
+ (void)armHop:(BOOL)enabled;
+ (void)reset;
+ (void)armMode:(NSInteger)mode;
@end
@implementation FocusProbe
+ (void)armHop:(BOOL)enabled { gHopAfterFirstCharacter=enabled; }
+ (void)reset {
  if(gInputDelegate && gFields.firstObject.inputDelegate==gInputDelegate)gFields.firstObject.inputDelegate=gInputDelegate.original;
  gInputDelegate=nil;gCallbackMode=0;[gWindow endEditing:YES];gHopAfterFirstCharacter=NO;
  for(UITextField *field in gFields)field.text=@"";
}
+ (void)armMode:(NSInteger)mode {
  gCallbackMode=mode;gHopAfterFirstCharacter=mode==1;
  if(mode==4){gInputDelegate=[FocusInputDelegate new];gInputDelegate.original=gFields.firstObject.inputDelegate;gFields.firstObject.inputDelegate=gInputDelegate;}
}
+ (BOOL)focus:(NSInteger)index {
  if (index<0) { [gWindow endEditing:YES]; return YES; }
  return index<(NSInteger)gFields.count && [gFields[index] becomeFirstResponder];
}
+ (NSDictionary *)state {
  id keyboard=[NSClassFromString(@"UIKeyboardImpl") activeInstance];
  id input=[keyboard respondsToSelector:@selector(inputDelegate)]?[keyboard inputDelegate]:nil;
  id responder=[gWindow firstResponder];
  NSMutableArray *fields=[NSMutableArray array];
  for (UITextField *field in gFields) [fields addObject:@{ @"id":field.accessibilityIdentifier,@"isFirstResponder":@(field.isFirstResponder),@"text":field.text?:@"" }];
  return @{ @"keyboardDelegate":Identity(input),@"windowFirstResponder":Identity(responder),@"keyboardDelegateIsUIKeyInput":@([input conformsToProtocol:@protocol(UIKeyInput)]),@"fields":fields };
}
@end
@interface VC : UIViewController <UITextFieldDelegate> @end
@implementation VC
- (BOOL)textField:(UITextField *)field shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString *)replacement {
  if(field==gFields.firstObject && replacement.length){
    if(gCallbackMode==2){gCallbackMode=0;[gFields[1] becomeFirstResponder];return YES;}
    if(gCallbackMode==3)return NO;
  }
  return YES;
}
- (void)viewDidLoad {
  [super viewDidLoad];self.view.backgroundColor=UIColor.whiteColor;
  UIView *wrapper=[[UIView alloc] initWithFrame:CGRectMake(20,100,360,140)];
  wrapper.isAccessibilityElement=YES;wrapper.accessibilityLabel=@"AX wrapper";wrapper.accessibilityIdentifier=@"wrapper";
  wrapper.backgroundColor=UIColor.systemGray6Color;[self.view addSubview:wrapper];
  NSMutableArray *fields=[NSMutableArray array];
  for (int i=0;i<4;i++) {
    UITextField *field=[[UITextField alloc] initWithFrame:CGRectMake(10,10+i*60,330,44)];
    field.delegate=self;field.borderStyle=UITextBorderStyleRoundedRect;field.placeholder=[NSString stringWithFormat:@"field%d",i];
    field.accessibilityIdentifier=[NSString stringWithFormat:@"field%d",i];
    field.autocorrectionType=UITextAutocorrectionTypeNo;field.autocapitalizationType=UITextAutocapitalizationTypeNone;
    [field addAction:[UIAction actionWithHandler:^(UIAction *action) {
      if(gHopAfterFirstCharacter && field==gFields.firstObject && field.text.length){
        gHopAfterFirstCharacter=NO;[gFields[1] becomeFirstResponder];
      }
    }] forControlEvents:UIControlEventEditingChanged];
    if(i<2)[wrapper addSubview:field];
    else if(i==2){field.frame=CGRectMake(20,280,350,44);[self.view addSubview:field];}
    else {UIView *hiddenAX=[[UIView alloc] initWithFrame:CGRectMake(20,350,350,60)];hiddenAX.accessibilityElementsHidden=YES;
      field.frame=CGRectMake(0,0,350,44);[hiddenAX addSubview:field];[self.view addSubview:hiddenAX];}
    [fields addObject:field];
  }
  gFields=fields;
}
@end
@interface SD : UIResponder <UIWindowSceneDelegate> @property(nonatomic,strong)UIWindow *window; @end
@implementation SD
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
  self.window=[[UIWindow alloc]initWithWindowScene:(UIWindowScene *)scene];gWindow=self.window;
  self.window.rootViewController=[VC new];[self.window makeKeyAndVisible];
}
@end
@interface AD : UIResponder <UIApplicationDelegate> @end
@implementation AD
- (UISceneConfiguration *)application:(UIApplication *)app configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
  UISceneConfiguration *configuration=[UISceneConfiguration configurationWithName:@"Default" sessionRole:session.role];configuration.delegateClass=SD.class;return configuration;
}
@end
int main(int argc,char **argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(AD.class));}}
