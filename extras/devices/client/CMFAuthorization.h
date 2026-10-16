#import <Foundation/Foundation.h>
// Capture delivery must recheck at its asynchronous delegate boundary.
FOUNDATION_EXPORT BOOL CMFAuthorizationAllowsCapture(void);
FOUNDATION_EXPORT uint64_t CMFAuthorizationGeneration(void);
FOUNDATION_EXPORT BOOL CMFAuthorizationAllowsGeneration(uint64_t generation);
