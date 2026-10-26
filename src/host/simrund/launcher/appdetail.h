// appdetail.h — the launcher's app pane: the selected app's icon, name and details, then its tabs. Profiles lists its
// data containers (its default one and its profiles) with what each runs as and its running instances, and creates
// new profiles. With no app selected, the pane says how to add apps.
#pragma once
#import <Cocoa/Cocoa.h>
#import "launcher.h"

@interface SRAppDetailController : NSViewController
- (instancetype)initWithDelegate:(id<SRLauncherDelegate>)delegate;
@property (nonatomic) SRAppInfo *app;                       // nil: the empty state
@property (nonatomic) BOOL libraryEmpty;                    // the empty state offers to add apps (else "No App Selected")
@property (copy) void (^onAddApp)(void), (^onAddXcodeBuilds)(void);
@property (copy) void (^onDrop)(NSArray<NSString *> *paths);   // .app bundles dropped on the pane

// The outline selects several profiles at once (⌘- and ⇧-click). Lists of profiles name the default one "default", as
// instancesOfApp: does; +[SREnvironment normalizedProfile:] makes that nil.
// The profiles selected in the Profiles outline, in its order (the default one when none is), and selecting one.
@property (readonly) NSArray<NSString *> *selectedProfiles;
- (void)selectProfile:(NSString *)profile;
@property (copy) void (^onSelectProfile)(void);             // the selection changed
@property (copy) void (^onOpenProfile)(NSString *profile);  // a profile was double-clicked
// The context menu of the outline's rows; profilesForMenu gives what it is for: the selected profiles when it opened on
// one of them, else the row it opened on (nil: none, e.g. empty space).
@property (nonatomic) NSMenu *profileMenu;
@property (readonly) NSArray<NSString *> *profilesForMenu;
// Asks whether to delete `profiles` (their data containers and launch options), then does. Not the default profile
// (skipped), and not while the app runs in any of them.
- (BOOL)canDeleteProfiles:(NSArray<NSString *> *)profiles;
- (void)deleteProfiles:(NSArray<NSString *> *)profiles;

- (void)reloadInfo;    // the app's launch options changed (or anything else in its details)
- (void)reloadState;   // an instance of it started or exited, or a container changed
@end
