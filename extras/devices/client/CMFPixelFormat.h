#import <AVFoundation/AVFoundation.h>

// Returns a retained sample in the requested output format, or NULL when the
// requested format cannot be produced. Preview continues to use the BGRA source.
CMSampleBufferRef CMFCopyVideoSample(CMSampleBufferRef source, OSType requested) CF_RETURNS_RETAINED;
