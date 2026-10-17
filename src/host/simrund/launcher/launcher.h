// launcher.h — the launcher window: the app library in a sidebar (drag-and-drop to add), the selected app's pane
// (appdetail.h), and the app commands in the toolbar.
#pragma once
#import <Cocoa/Cocoa.h>
#import "apps/library.h"

typedef NS_ENUM(NSInteger, SRAppState) {
  SRAppStateStopped,
  SRAppStateLaunching,   // process started, no frame yet (window still hidden)
  SRAppStateRunning,     // window shown
};

// The launcher acts on an app in one of its profiles: `profile` nil is its default data container.
@protocol SRLauncherDelegate <NSObject>
- (void)launchApp:(SRAppInfo *)app profile:(NSString *)profile;     // launches, or brings the running instance to the front
- (void)relaunchApp:(SRAppInfo *)app profile:(NSString *)profile;   // quits the running instance (if any), then launches
- (SRAppState)stateForApp:(SRAppInfo *)app profile:(NSString *)profile;
- (void)quitApp:(SRAppInfo *)app profile:(NSString *)profile;
- (void)showLogForApp:(SRAppInfo *)app profile:(NSString *)profile;
- (void)resetDataForApp:(SRAppInfo *)app profile:(NSString *)profile;   // deletes that data container (the app isn't running in it)
// Deletes one of its profiles (not the default one): its data container and launch options. Not while it runs in it.
- (void)deleteProfile:(NSString *)profile ofApp:(SRAppInfo *)app;
// Its running instances (launching ones too) by profile, "default" for its default container: their pids.
- (NSDictionary<NSString *, NSArray<NSNumber *> *> *)instancesOfApp:(SRAppInfo *)app;
@end

@interface SRLauncher : NSObject
- (instancetype)initWithDelegate:(id<SRLauncherDelegate>)delegate;
- (void)show;
- (void)reloadState;                           // an app's state changed
// Validates, adds to the library and launches the given .app paths; reports problems in an alert.
- (void)openPaths:(NSArray<NSString *> *)paths;
- (void)addAppWithPanel;
- (void)addXcodeBuilds;
// The Launch With… sheet for `app`'s `profile` on the launcher window; Launch saves its options and (re)launches it.
- (void)showLaunchOptionsForApp:(SRAppInfo *)app profile:(NSString *)profile;
@end
