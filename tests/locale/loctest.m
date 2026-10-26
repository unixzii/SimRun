// loctest — the locale, languages and time zone Foundation sees, and what the formatters make of them.
// Run with `simrun run build/tests/loctest`: the result should match the Mac's language & region settings (and time zone).
#import <Foundation/Foundation.h>
#include <time.h>

int main(void) {
  @autoreleasepool {
    NSDate *d = [NSDate dateWithTimeIntervalSince1970:1760000000];   // 2025-10-09 08:53:20 UTC
    printf("currentLocale      %s\n", NSLocale.currentLocale.localeIdentifier.UTF8String);
    printf("autoupdatingLocale %s\n", NSLocale.autoupdatingCurrentLocale.localeIdentifier.UTF8String);
    printf("preferredLanguages %s\n", [NSLocale.preferredLanguages componentsJoinedByString:@","].UTF8String);
    printf("region             %s\n", [NSLocale.currentLocale objectForKey:NSLocaleCountryCode] ? [[NSLocale.currentLocale objectForKey:NSLocaleCountryCode] UTF8String] : "(nil)");
    printf("calendar           %s\n", NSCalendar.currentCalendar.calendarIdentifier.UTF8String);
    printf("firstWeekday       %lu\n", (unsigned long)NSCalendar.currentCalendar.firstWeekday);
    printf("systemTimeZone     %s\n", NSTimeZone.systemTimeZone.name.UTF8String);
    printf("localTimeZone      %s (%s)\n", NSTimeZone.localTimeZone.name.UTF8String, NSTimeZone.localTimeZone.abbreviation.UTF8String);
    time_t t = 1760000000;
    struct tm tm;
    localtime_r(&t, &tm);
    printf("localtime_r        %02d:%02d %s (TZ=%s)\n", tm.tm_hour, tm.tm_min, tm.tm_zone, getenv("TZ") ?: "(unset)");

    NSDateFormatter *f = [NSDateFormatter new];
    f.dateStyle = NSDateFormatterFullStyle;
    f.timeStyle = NSDateFormatterFullStyle;
    printf("full style         '%s'\n", [f stringFromDate:d].UTF8String);
    f.dateStyle = NSDateFormatterShortStyle;
    f.timeStyle = NSDateFormatterShortStyle;
    printf("short style        '%s'\n", [f stringFromDate:d].UTF8String);
    f.dateFormat = @"yyyy-MM-dd HH:mm zzz";
    printf("fixed format       '%s'\n", [f stringFromDate:d].UTF8String);
    printf("template           '%s'\n", [NSDateFormatter dateFormatFromTemplate:@"yMMMdjm" options:0 locale:NSLocale.currentLocale].UTF8String);
    NSNumberFormatter *n = [NSNumberFormatter new];
    n.numberStyle = NSNumberFormatterCurrencyStyle;
    printf("currency           '%s'\n", [n stringFromNumber:@1234.5].UTF8String);
    printf("description        '%s'\n", [d descriptionWithLocale:NSLocale.currentLocale].UTF8String);
    printf("measurement uses   %s\n", [[NSLocale.currentLocale objectForKey:NSLocaleUsesMetricSystem] boolValue] ? "metric" : "imperial");
    printf("relative           '%s'\n", [[NSRelativeDateTimeFormatter new] localizedStringForDate:[NSDate dateWithTimeIntervalSinceNow:-3600] relativeToDate:NSDate.date].UTF8String);
  }
  return 0;
}
