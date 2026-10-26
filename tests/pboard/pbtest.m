// pbtest — UIPasteboard from a sim process (exercises the pboard module; see docs/pasteboard.md).
//   pbtest                 self-test: write/read text, several items and types, an image, a named pasteboard
//   pbtest get             print the general pasteboard (types per item, string)
//   pbtest set <text>      put text on the general pasteboard
//   pbtest watch [secs]    print the general pasteboard whenever it changes (notification or changeCount)
#import <UIKit/UIKit.h>

static int gFail;
static void check(BOOL ok, NSString *what) {
  printf("%s %s\n", ok ? "ok  " : "FAIL", what.UTF8String);
  if (!ok) {
    gFail++;
  }
}

static void dump(UIPasteboard *pb) {
  printf("changeCount %ld, %ld items\n", (long)pb.changeCount, (long)pb.numberOfItems);
  [[pb pasteboardTypesForItemSet:nil] enumerateObjectsUsingBlock:^(NSArray<NSString *> *ts, NSUInteger i, BOOL *stop) {
    printf("  item %lu: %s\n", (unsigned long)i, [[ts componentsJoinedByString:@", "] UTF8String]);
  }];
  printf("string: %s\n", pb.hasStrings ? [pb.string UTF8String] : "(none)");
}

static void selftest(void) {
  UIPasteboard *pb = UIPasteboard.generalPasteboard;
  NSInteger c0 = pb.changeCount;
  NSString *s = [NSString stringWithFormat:@"pbtest %@", NSUUID.UUID.UUIDString];
  pb.string = s;
  check([pb.string isEqual:s], @"string round trip");
  check(pb.changeCount > c0, [NSString stringWithFormat:@"changeCount advanced (%ld -> %ld)", (long)c0, (long)pb.changeCount]);

  pb.items = @[ @{ @"public.utf8-plain-text": @"first", @"public.html": [@"<b>first</b>" dataUsingEncoding:NSUTF8StringEncoding] },
                @{ @"public.utf8-plain-text": @"second" } ];
  check(pb.numberOfItems == 2, @"two items");
  check([pb.strings isEqual:(@[ @"first", @"second" ])], [NSString stringWithFormat:@"strings %@", pb.strings]);
  NSData *html = [pb dataForPasteboardType:@"public.html"];
  check([[[NSString alloc] initWithData:html encoding:NSUTF8StringEncoding] isEqual:@"<b>first</b>"], @"html representation");

  UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(8, 8)];
  UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
    [UIColor.redColor setFill];
    [ctx fillRect:CGRectMake(0, 0, 8, 8)];
  }];
  pb.image = img;
  check(pb.hasImages && pb.image.size.width > 0, [NSString stringWithFormat:@"image round trip (%@)", NSStringFromCGSize(pb.image.size)]);

  UIPasteboard *named = [UIPasteboard pasteboardWithName:@"dev.simrun.pbtest" create:YES];
  named.string = @"named";
  check([[UIPasteboard pasteboardWithName:@"dev.simrun.pbtest" create:NO].string isEqual:@"named"], @"named pasteboard");

  pb.string = s;   // leave something recognizable behind (pbpaste on the Mac should print it)
  usleep(300000);  // the save reaches the pasteboard server asynchronously: don't exit before it lands
  printf("%s (general pasteboard now holds \"%s\")\n", gFail ? "FAILED" : "PASSED", s.UTF8String);
}

int main(int argc, char **argv) {
  @autoreleasepool {
    NSString *cmd = argc > 1 ? @(argv[1]) : nil;
    UIPasteboard *pb = UIPasteboard.generalPasteboard;
    if (!cmd) {
      selftest();
      return gFail ? 1 : 0;
    }
    if ([cmd isEqual:@"get"]) {
      dump(pb);
      return 0;
    }
    if ([cmd isEqual:@"set"] && argc > 2) {
      pb.string = @(argv[2]);
      dump(pb);
      return 0;
    }
    if ([cmd isEqual:@"watch"]) {
      dump(pb);
      // UIKit posts the notification for this process's own changes only; others show up as a new changeCount
      [NSNotificationCenter.defaultCenter addObserverForName:UIPasteboardChangedNotification object:nil queue:NSOperationQueue.mainQueue
                                                  usingBlock:^(NSNotification *n) {
        printf("-- changed (notification)\n");
        dump(pb);
        fflush(stdout);
      }];
      __block NSInteger seen = pb.changeCount;
      [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *t) {
        if (pb.changeCount == seen) {
          return;
        }
        seen = pb.changeCount;
        printf("-- changed (changeCount)\n");
        dump(pb);
        fflush(stdout);
      }];
      CFRunLoopRunInMode(kCFRunLoopDefaultMode, argc > 2 ? atof(argv[2]) : 30, false);
      return 0;
    }
    fprintf(stderr, "usage: pbtest [get | set <text> | watch [secs]]\n");
    return 2;
  }
}
