// keychainwindow.h — the Keychain window: every item in SimRun's fake keychain (include/keychain.h), passwords in
// plaintext. Follows the file as apps change it; passwords can be edited and items deleted.
#pragma once
#import <Cocoa/Cocoa.h>

@interface SRKeychainWindow : NSObject
+ (instancetype)shared;
// Shows the window; `filter` (e.g. an app's bundle id) goes into the search field, nil keeps the current one.
- (void)showWithFilter:(NSString *)filter;
@end
