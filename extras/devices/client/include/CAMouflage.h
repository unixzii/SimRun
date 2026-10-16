#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Returns YES when the in-process SimRun camera service is connected.
/// Waits briefly for the initial device list. Device builds return NO.
FOUNDATION_EXPORT BOOL CAMouflageIsProviderConnected(void);

/// Configure explicit sources for this simulator process. For example:
///
///     {"devices":[{"id":"image-back","position":"back",
///       "source":{"kind":"image","path":"/absolute/image.png"}}]}
///
/// Sources are image (absolute path or dataBase64) and screen (the visible
/// requesting SimRun viewport). No default/menu source is selected.
/// The configuration is not persisted, is resent after service reconnect,
/// and is discarded at process exit or CAMouflageClearMockConfiguration().
/// Returns NO for invalid JSON. A disconnected service queues valid JSON and
/// returns YES; this acknowledges queueing, not host source validation.
/// Host validation errors arrive asynchronously. Device builds return NO.
FOUNDATION_EXPORT BOOL CAMouflageSetMockConfiguration(NSData *configurationJSON);

/// Simulates app-side video authorization only. JSON keys: authorization
/// (notDetermined / authorized / denied / restricted), requestAuthorization
/// (authorized / denied). Both default to authorized. No host TCC is changed.
/// Revoking authorization stops sessions; callers explicitly start them again
/// after granting. Returns NO for an invalid configuration without changing state.
FOUNDATION_EXPORT BOOL CAMouflageSetAuthorizationConfiguration(NSData *configurationJSON);

/// Stop this process's sessions and clear its explicit sources; no fallback source.
FOUNDATION_EXPORT void CAMouflageClearMockConfiguration(void);

NS_ASSUME_NONNULL_END
