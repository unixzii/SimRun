#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>

/// Delivered on the frame stream's read queue. The sample buffer is valid only
/// for the duration of the call; retain it before handing it elsewhere.
typedef void (^CMFFrameHandler)(uint32_t sessionId, CMSampleBufferRef sampleBuffer);

void CMFFrameStreamSetHandler(CMFFrameHandler handler);
void CMFFrameStreamStart(uint32_t sessionId);
void CMFFrameStreamStop(uint32_t sessionId);
