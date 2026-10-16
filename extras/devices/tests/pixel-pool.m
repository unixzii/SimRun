// Runtime check of eviction while another caller owns a retained pixel pool.
#import "../client/CMFFrameStream.m"
int main(void) { @autoreleasepool {
  CVPixelBufferPoolRef held = cmf_copy_pixel_buffer_pool(32, 32);
  __block int failures = 0;
  dispatch_apply(400, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t i) { @autoreleasepool {
    size_t side = 32 + (i % 20) * 2;
    CVPixelBufferPoolRef pool = cmf_copy_pixel_buffer_pool(side, side);
    CVPixelBufferRef pixel = NULL;
    CVReturn result = pool ? CVPixelBufferPoolCreatePixelBuffer(NULL, pool, &pixel) : -1;
    if (result || !pixel || CVPixelBufferGetWidth(pixel) != side) @synchronized (gPixelBufferPools) { failures++; }
    if (pixel) CFRelease(pixel);
    if (pool) CFRelease(pool);
  }});
  CVPixelBufferRef pixel = NULL;
  CVReturn heldResult = held ? CVPixelBufferPoolCreatePixelBuffer(NULL, held, &pixel) : -1;
  if (pixel) CFRelease(pixel);
  if (held) CFRelease(held);
  __block NSUInteger cacheCount;
  dispatch_sync(gPixelBufferPoolQueue, ^{ cacheCount = gPixelBufferPools.count; });
  printf("POOL_RESULT {\"allocations\":400,\"failures\":%d,\"heldAfterEviction\":%s,\"cachedSizes\":%lu}\n", failures, heldResult == 0 ? "true" : "false", (unsigned long)cacheCount);
  return failures || heldResult || cacheCount > 4;
}}
