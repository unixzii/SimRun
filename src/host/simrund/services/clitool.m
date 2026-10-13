// clitool.m — SimRun ▸ Install Command Line Tool… (clitool.h).
//
// /usr/local/bin is on the default PATH (/etc/paths) but belongs to root on a fresh Mac, so the link is made directly
// when the user can write there (Homebrew on Intel Macs makes it theirs) and otherwise by `do shell script ... with
// administrator privileges`, which shows macOS's own password dialog in SimRun's name. That runs on a background queue:
// app windows keep drawing while the dialog is up.
#import <Cocoa/Cocoa.h>
#include <sys/stat.h>
#include "services/clitool.h"

static NSString *const kBinDir = @"/usr/local/bin", *const kLink = @"/usr/local/bin/simrun";
static BOOL gInstalling;

typedef NS_ENUM(NSInteger, SRLinkState) { SRLinkNone, SRLinkOurs, SRLinkOther, SRLinkFolder };

static NSString *Helper(void) {
  NSString *p = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Contents/Helpers/simrun"];
  return access(p.fileSystemRepresentation, X_OK) == 0 ? p : nil;
}

// What's at /usr/local/bin/simrun now; for something else there, *what says what it is.
static SRLinkState Existing(NSString *helper, NSString **what) {
  struct stat st;
  if (lstat(kLink.fileSystemRepresentation, &st) != 0) return SRLinkNone;
  if (S_ISDIR(st.st_mode)) return SRLinkFolder;
  if (!S_ISLNK(st.st_mode)) { *what = @"It's a file, not a link to SimRun's simrun."; return SRLinkOther; }
  char a[PATH_MAX], b[PATH_MAX];   // realpath: the same simrun however the link gets there
  if (realpath(kLink.fileSystemRepresentation, a) && realpath(helper.fileSystemRepresentation, b) && !strcmp(a, b)) return SRLinkOurs;
  NSString *dest = [NSFileManager.defaultManager destinationOfSymbolicLinkAtPath:kLink error:nil] ?: @"?";
  if (!dest.isAbsolutePath) dest = [kBinDir stringByAppendingPathComponent:dest].stringByStandardizingPath;
  BOOL dangling = stat(kLink.fileSystemRepresentation, &st) != 0;
  *what = [NSString stringWithFormat:@"It links to %@%@.", dest.stringByAbbreviatingWithTildeInPath, dangling ? @", which no longer exists" : @""];
  return SRLinkOther;
}

// Links it as the user: a new link renamed over the old one. Returns 0 or the errno.
static int LinkDirectly(NSString *helper) {
  if (mkdir(kBinDir.fileSystemRepresentation, 0755) != 0 && errno != EEXIST) return errno;
  NSString *tmp = [kBinDir stringByAppendingPathComponent:[NSString stringWithFormat:@".simrun.%d", getpid()]];
  unlink(tmp.fileSystemRepresentation);
  if (symlink(helper.fileSystemRepresentation, tmp.fileSystemRepresentation) != 0) return errno;
  if (rename(tmp.fileSystemRepresentation, kLink.fileSystemRepresentation) != 0) { int e = errno; unlink(tmp.fileSystemRepresentation); return e; }
  return 0;
}

static NSString *ShellQuoted(NSString *s) { return [NSString stringWithFormat:@"'%@'", [s stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]]; }
static NSString *ScriptQuoted(NSString *s) {
  s = [s stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
  return [NSString stringWithFormat:@"\"%@\"", [s stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""]];
}

// Links it as root, after macOS asks for an administrator's password. Returns nil, @"" if the user cancelled, or why
// it failed.
static NSString *LinkAsAdmin(NSString *helper) {
  NSString *sh = [NSString stringWithFormat:@"/bin/mkdir -p %@ && /bin/ln -sfh %@ %@", kBinDir, ShellQuoted(helper), kLink];
  NSString *src = [NSString stringWithFormat:@"do shell script %@ with prompt %@ with administrator privileges", ScriptQuoted(sh),
                   ScriptQuoted(@"SimRun wants to install the simrun command in /usr/local/bin.")];
  NSDictionary *err = nil;
  [[[NSAppleScript alloc] initWithSource:src] executeAndReturnError:&err];
  if (!err) return nil;
  if ([err[NSAppleScriptErrorNumber] integerValue] == -128) return @"";   // userCanceledErr
  return err[NSAppleScriptErrorMessage] ?: @"The administrator script failed.";
}

static void Report(NSString *title, NSString *text, NSAlertStyle style) {
  NSAlert *al = [NSAlert new]; al.messageText = title; al.informativeText = text; al.alertStyle = style;
  [NSApp activateIgnoringOtherApps:YES];   // back from the password dialog
  [al runModal];
}

@implementation SRCommandLineTool

+ (BOOL)canInstall { return !gInstalling && Helper() != nil; }

+ (void)install {
  NSString *helper = Helper();
  if (!helper || gInstalling) return;
  NSString *what = nil;
  switch (Existing(helper, &what)) {
    case SRLinkNone: break;
    case SRLinkOurs:
      Report(@"The simrun command is already installed", [NSString stringWithFormat:@"%@ links to the simrun in this copy of SimRun.", kLink], NSAlertStyleInformational);
      return;
    case SRLinkFolder:
      Report(@"Couldn't install the simrun command", [NSString stringWithFormat:@"%@ is a folder. Move it away, then try again.", kLink], NSAlertStyleWarning);
      return;
    case SRLinkOther: {
      NSAlert *al = [NSAlert new];
      al.messageText = @"Replace the existing simrun command?";
      al.informativeText = [NSString stringWithFormat:@"%@ already exists. %@\n\nReplacing it links it to the simrun in this copy of SimRun.", kLink, what];
      [al addButtonWithTitle:@"Replace"];
      [al addButtonWithTitle:@"Cancel"];
      if ([al runModal] != NSAlertFirstButtonReturn) return;
    }
  }

  int e = LinkDirectly(helper);
  if (e == 0) { [self reportInstalled]; return; }
  if (e != EACCES && e != EPERM) {
    Report(@"Couldn't install the simrun command", [NSString stringWithFormat:@"%@: %s", kLink, strerror(e)], NSAlertStyleWarning);
    return;
  }
  gInstalling = YES;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSString *failure = LinkAsAdmin(helper);
    dispatch_async(dispatch_get_main_queue(), ^{
      gInstalling = NO;
      if (!failure) [self reportInstalled];
      else if (failure.length) Report(@"Couldn't install the simrun command", failure, NSAlertStyleWarning);
    });
  });
}

+ (void)reportInstalled {
  Report(@"Installed the simrun command",
         [NSString stringWithFormat:@"%@ now links to the simrun in this copy of SimRun. Open a new terminal window and run `simrun help`.", kLink],
         NSAlertStyleInformational);
}

@end
