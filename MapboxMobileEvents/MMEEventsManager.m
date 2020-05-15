@import CoreFoundation;
@import CoreLocation;

#if TARGET_OS_OSX
@import AppKit;
#elif TARGET_OS_IOS || TARGET_OS_TVOS
@import UIKit;
#endif

#import "CLLocation+MMEMobileEvents.h"
#import "CLLocationManager+MMEMobileEvents.h"
#import "MMEEventsManager.h"
#import "MMEEventsManager_Private.h"
#import "MMEAPIClient.h"
#import "MMEAPIClient_Private.h"
#import "MMEConstants.h"
#import "MMEDate.h"
#import "MMEDispatchManager.h"
#import "MMEEvent.h"
#import "MMELogger.h"
#import "MMELocationManager.h"
#import "MMEMetricsManager.h"
#import "MMEUIApplicationWrapper.h"
#import "MMEUniqueIdentifier.h"
#import "NSUserDefaults+MMEConfiguration.h"
#import "NSProcessInfo+SystemInfo.h"
#import "MMEConfigService.h"
#import "MMEPreferences.h"
#import "NSError+APIClient.h"

NS_ASSUME_NONNULL_BEGIN

@interface MMEAPIClient () <MMEAPIClient>
@end

// MARK: -

@interface MMEEventsManager () <MMELocationManagerDelegate>

@property (nonatomic) id<MMELocationManager> locationManager;
@property (nonatomic) NS_MUTABLE_ARRAY_OF(MMEEvent *) *eventQueue;
@property (nonatomic) MMEPreferences* preferences;
@property (nonatomic) id<MMEUniqueIdentifer> uniqueIdentifer;
@property (nonatomic) NSDate *nextTurnstileSendDate;
@property (nonatomic) NSTimer *queueTimer;
@property (nonatomic) MMEDispatchManager *dispatchManager;
@property (nonatomic, getter=isPaused) BOOL paused;
@property (nonatomic) id<MMEUIApplicationWrapper> application;
@property (nonatomic) UIBackgroundTaskIdentifier backgroundTaskIdentifier;
@property (nonatomic) MMELogger *logger;
@property (nonatomic) MMEMetricsManager *metricsManager;
@property (nullable, nonatomic) MMEConfigService* configService;

@property (nonatomic, strong) NSMutableArray<OnURLResponse>* urlResponseListeners;
@property (nonatomic, strong) NSMutableArray<OnSerializationError>* serializationErrorListeners;

@end

// MARK: -

@implementation MMEEventsManager

+ (instancetype)sharedManager {
    static MMEEventsManager *_sharedManager;
    static dispatch_once_t onceToken;
    
    dispatch_once(&onceToken, ^{
        _sharedManager = [[MMEEventsManager alloc] initWithDefaults];
    });
    
    return _sharedManager;
}

/*! @Brief Initializes new instance of EventsManager with default values */
- (instancetype)initWithDefaults {
    MMELogger* logger = [[MMELogger alloc] init];
    MMEPreferences* preferences = [[MMEPreferences alloc] initWithBundle:NSBundle.mainBundle
                                                               dataStore:NSUserDefaults.mme_configuration];
    MMEMetricsManager* metricsManager = [[MMEMetricsManager alloc] initWithLogger:logger config:preferences];

    return [self initWithPreferences:preferences
               uniqueIdentifier:[[MMEUniqueIdentifier alloc] initWithTimeInterval:self.preferences.identifierRotationInterval]
                    application:[[MMEUIApplicationWrapper alloc] init]
                 metricsManager:metricsManager
                dispatchManager:[[MMEDispatchManager alloc] init]
                         logger:logger];
}

/*! @Brief Designated Initializer */
- (instancetype)initWithPreferences:(MMEPreferences*)preferences
              uniqueIdentifier:(MMEUniqueIdentifier*)uniqueIdentifier
                   application:(id <MMEUIApplicationWrapper>)application
                metricsManager:(MMEMetricsManager*)metricsManager
               dispatchManager:(MMEDispatchManager*)dispatchManager
                        logger:(MMELogger*)logger {
    if (self = [super init]) {
        self.paused = YES;
        self.eventQueue = [NSMutableArray array];
        self.preferences = preferences;
        self.uniqueIdentifer = uniqueIdentifier;
        self.application = application;
        self.metricsManager = metricsManager;
        self.dispatchManager = dispatchManager;
        self.logger = logger;
        self.urlResponseListeners = [NSMutableArray array];
    }
    return self;

}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self pauseMetricsCollection];
}

-(id <MMEEventConfigProviding>)configuration {
    return self.preferences;
}

- (void)startEventsManagerWithToken:(NSString *)accessToken {
    [self startEventsManagerWithToken:accessToken userAgentBase:@"legacy" hostSDKVersion:@"0.0"];
}

- (void)startEventsManagerWithToken:(NSString *)accessToken userAgentBase:(NSString *)userAgentBase hostSDKVersion:(NSString *)hostSDKVersion {
    @try {
        if (self.apiClient) { // stop the existing API client, set the new token then recreate the client
            [self stopEventsManager];
        }
        self.preferences.accessToken = accessToken;
        self.preferences.legacyUserAgentBase = userAgentBase;
        self.preferences.legacyHostSDKVersion = hostSDKVersion;

        __weak __typeof__(self) weakSelf = self;


        // Setup Client
        // Use function accessors instead of properties for easier memory management
        // Given we can message null, a method call to null will return null.
        // This save time unwrapping if (weakSelf) each time we're accessing a nullable object's property
        self.apiClient = [[MMEAPIClient alloc] initWithConfig:self.preferences
                        onSerializationError:^(NSError * _Nonnull error) {
            [weakSelf reportError:error];
        } onURLResponse:^(NSData * _Nullable data, NSURLRequest * _Nonnull request, NSURLResponse * _Nullable response, NSError * _Nullable error) {

            // Generic URL Response Tracking (Network Errors / Bytes)
            __strong __typeof__(weakSelf) strongSelf = weakSelf;
            if (!strongSelf){
                return;
            }

            if (response && [response isKindOfClass:NSHTTPURLResponse.class]) {
                NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
                NSError *statusError = [[NSError alloc] initWith:request httpResponse:httpResponse error:error];

                // General Error Reporting
                if (statusError) {
                    [strongSelf reportError:statusError];
                }

                // Report Metrics
                if (data) {
                    [strongSelf.metricsManager updateReceivedBytes:data.length];
                }
            }
            else if (error) {
                // General Error Reporting
                [strongSelf reportError:error];
            }

            // Notify Registered Listeners
            for (OnURLResponse listener in self.urlResponseListeners) {
                listener(data, request, response, error);
            }

        } onEventQueueUpdate:^(NSArray * _Nonnull eventQueue) {
            [[weakSelf metricsManager] updateMetricsFromEventQueue:eventQueue];

        } onEventCountUpdate:^(NSUInteger eventCount, NSURLRequest * _Nullable request, NSError * _Nullable error) {
            [[weakSelf metricsManager] updateMetricsFromEventCount:eventCount request:request error:error];
        } onGenerateTelemetryEvent:^{
            [[weakSelf metricsManager] generateTelemetryMetricsEvent];
        }];

        // Setup Service to Poll/Handle Configuration updates
        self.configService = [[MMEConfigService alloc] init:self.preferences
                                                     client:self.apiClient
                                               onConfigLoad:^(MMEConfig * _Nonnull config) {

             __strong __typeof__(weakSelf) strongSelf = weakSelf;
            if (strongSelf) {
                [strongSelf.preferences updateWithConfig:config];
            }
        }];
        
        [self.configService startUpdates];


        [self sendPendingTelemetryMetricsEvent];

        void(^initialization)(void) = ^{
            __strong __typeof__(weakSelf) strongSelf = weakSelf;

            if (strongSelf == nil) {
                return;
            }

            [NSNotificationCenter.defaultCenter addObserver:strongSelf
                selector:@selector(pauseOrResumeMetricsCollectionIfRequired)
                name:UIApplicationDidEnterBackgroundNotification
                object:nil];
            [NSNotificationCenter.defaultCenter addObserver:strongSelf
                selector:@selector(pauseOrResumeMetricsCollectionIfRequired)
                name:UIApplicationDidBecomeActiveNotification
                object:nil];

            if (@available(iOS 9.0, *)) {
                [NSNotificationCenter.defaultCenter addObserver:strongSelf
                    selector:@selector(powerStateDidChange:)
                    name:NSProcessInfoPowerStateDidChangeNotification
                    object:nil];
            }

            strongSelf.paused = YES;
            strongSelf.locationManager = [[MMELocationManager alloc] initWithMetricsManager: self.metricsManager
                                                                                     config:self.preferences];
            strongSelf.locationManager.delegate = strongSelf;
            [strongSelf resumeMetricsCollection];
        };

        [self.dispatchManager scheduleBlock:initialization afterDelay:self.preferences.startupDelay];
    }
    @catch(NSException *except) {
        [self reportException:except];
    }
}

- (void)stopEventsManager {
    [self flushEventsManager]; // send any pending events
    [self sendPendingTelemetryMetricsEvent]; // send then reset any metrics
    self.apiClient = nil;
}

// MARK: - NSNotifications

- (void)powerStateDidChange:(NSNotification *)notification {
    // From https://github.com/mapbox/mapbox-events-ios/issues/44 it looks like
    // `NSProcessInfoPowerStateDidChangeNotification` can be sent from a thread other than the main
    // thread.
    
    __weak __typeof__(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf pauseOrResumeMetricsCollectionIfRequired];
    });
}

- (void)pauseOrResumeMetricsCollectionIfRequired {
    @try {
        BOOL appIsInBackground = (self.application.applicationState == UIApplicationStateBackground);

        // check for existing background task status, flush the event queue if needed
        if (appIsInBackground && _backgroundTaskIdentifier == UIBackgroundTaskInvalid) {
            MMELog(MMELogInfo, MMEDebugEventTypeBackgroundTask, ([NSString stringWithFormat:@"Initiated background task: %@, instance: %@",
                @(self.backgroundTaskIdentifier),self.uniqueIdentifer.rollingInstanceIdentifer ?: @"nil"]));

            __weak __typeof__(self) weakSelf = self;
            _backgroundTaskIdentifier = [self.application beginBackgroundTaskWithExpirationHandler:^{

                MMELog(
                       MMELogInfo,
                       MMEDebugEventTypeBackgroundTask,
                       ([NSString stringWithFormat:@"Ending background task: %@, instance: %@", @(weakSelf.backgroundTaskIdentifier) ?: @"nil", weakSelf.uniqueIdentifer.rollingInstanceIdentifer ?: @"nil"])
                       );
                
                [weakSelf.application endBackgroundTask:self.backgroundTaskIdentifier];
                weakSelf.backgroundTaskIdentifier = UIBackgroundTaskInvalid;
            }];
            
            [self flush];
        }
                
        [self processAuthorizationStatus:[CLLocationManager authorizationStatus] andApplicationState:self.application.applicationState];
    }
    @catch(NSException *except) {
        [self reportException:except];
    }
}

- (void)processAuthorizationStatus:(CLAuthorizationStatus)authStatus andApplicationState:(UIApplicationState)applicationState {

    // check the system authorization status, then decide what we should be doing
    if (authStatus == kCLAuthorizationStatusAuthorizedAlways) {

        if (((applicationState != UIApplicationStateBackground && self.preferences.isCollectionEnabled)
         || (applicationState == UIApplicationStateBackground && self.preferences.isCollectionEnabledInBackground))
         && self.isPaused) {
            [self resumeMetricsCollection];
        } else if ((applicationState == UIApplicationStateBackground
                   && self.preferences.isCollectionEnabledInBackground == NO)
                   || self.preferences.isCollectionEnabled == NO) {
            [self pauseMetricsCollection];
        }
    } else if (authStatus == kCLAuthorizationStatusAuthorizedWhenInUse) {
        if (self.preferences.isCollectionEnabled && self.paused) {  // Prevent blue status bar
            [self resumeMetricsCollection];
        } else if (applicationState == UIApplicationStateBackground) { // check for user preferences
            [self pauseMetricsCollection];
        } else if (!self.preferences.isCollectionEnabled) {
            [self pauseMetricsCollection];
        }
    } else {
        [self pauseMetricsCollection];
    }
}

- (void)flushEventsManager {
    @try {
        if (self.paused) {
            return;
        }

        if (self.preferences.accessToken == nil) {
            return;
        }

        if (self.eventQueue.count == 0) {
            return;
        }

        [self sendTelemetryMetricsEvent];

        NSArray *events = [self.eventQueue copy];
        [self postEvents:events];
        [self resetEventQueuing];

        if (self.delegate && [self.delegate respondsToSelector:@selector(eventsManager:didSendEvents:)]) {
            [self.delegate eventsManager:self didSendEvents:events];
        }

        MMELog(MMELogInfo, MMEDebugEventTypeFlush, ([NSString stringWithFormat:@"flush, instance: %@",
            self.uniqueIdentifer.rollingInstanceIdentifer ?: @"nil"]));
    }
    @catch(NSException *except) {
        [self reportException:except];
    }
}

- (void)resetEventQueuing {
    @try {
        [self.eventQueue removeAllObjects];
        [self.queueTimer invalidate];
    }
    @catch(NSException *except) {
        [self reportException:except];
    }

}

- (void)postEvents:(NSArray *)events {
    @try {
        __weak __typeof__(self) weakSelf = self;
        [self.apiClient postEvents:events completionHandler:^(NSError * _Nullable error) {
            @try {
                __strong __typeof__(weakSelf) strongSelf = weakSelf;
                if (strongSelf == nil) {
                    return;
                }
                if (error) {
                    [self.logger logEvent:[MMEEvent debugEventWithError:error]];
                } else {
                    MMELog(MMELogInfo, MMEDebugEventTypePost, ([NSString stringWithFormat:@"post: %@, instance: %@",
                        @(events.count),strongSelf.uniqueIdentifer.rollingInstanceIdentifer ?: @"nil"]));
                }

                if (strongSelf.backgroundTaskIdentifier != UIBackgroundTaskInvalid) {
                    MMELog(MMELogInfo, MMEDebugEventTypeBackgroundTask, ([NSString stringWithFormat:@"Ending background task: %@, instance: %@",@(strongSelf.backgroundTaskIdentifier),strongSelf.uniqueIdentifer.rollingInstanceIdentifer ?: @"nil"]));
                    
                    [strongSelf.application endBackgroundTask:strongSelf.backgroundTaskIdentifier];
                    strongSelf.backgroundTaskIdentifier = UIBackgroundTaskInvalid;
                }
            }
            @catch(NSException *except) {
                [self reportException:except];
            }
        }];
    }
    @catch(NSException *except) {
        [self reportException:except];
    }
}

- (void)sendTurnstileEvent {
    @try {
        if (self.nextTurnstileSendDate && ([NSDate.date timeIntervalSinceDate:self.nextTurnstileSendDate] < 0)) {
            MMELog(MMELogInfo, MMEDebugEventTypeTurnstile, ([NSString stringWithFormat:@"Turnstile event already sent; waiting until %@ to send another one, instance: %@",
                self.nextTurnstileSendDate, self.uniqueIdentifer.rollingInstanceIdentifer ?: @"nil"]));
            return;
        }

        if (!self.preferences.accessToken) {
            MMELog(MMELogInfo, MMEDebugEventTypeTurnstileFailed, ([NSString stringWithFormat:@"No access token sent - can not send turntile event, instance: %@",
                self.uniqueIdentifer.rollingInstanceIdentifer ?: @"nil"]));
            return;
        }

        if (!NSProcessInfo.mme_vendorId) {
            MMELog(MMELogInfo, MMEDebugEventTypeTurnstileFailed, ([NSString stringWithFormat:@"No vendor id available - can not send turntile event, instance: %@",
                self.uniqueIdentifer.rollingInstanceIdentifer ?: @"nil"]));
            return;
        }

        if (!NSProcessInfo.mme_deviceModel) {
            MMELog(MMELogInfo, MMEDebugEventTypeTurnstileFailed, ([NSString stringWithFormat:@"No model available - can not send turntile event, instance: %@",
                self.uniqueIdentifer.rollingInstanceIdentifer ?: @"nil"]));
            return;
        }

        if (!NSProcessInfo.mme_osVersion) {
            MMELog(MMELogInfo, MMEDebugEventTypeTurnstileFailed, ([NSString stringWithFormat:@"No iOS version available - can not send turntile event, instance: %@",
                self.uniqueIdentifer.rollingInstanceIdentifer ?: @"nil"]));
            return;
        }

        // TODO: remove this check when we switch to reformed UA strings for the events api
        if (!self.preferences.legacyUserAgentBase) {
            MMELog(MMELogInfo, MMEDebugEventTypeTurnstileFailed, ([NSString stringWithFormat:@"No user agent base set - can not send turntile event, instance: %@",
                self.uniqueIdentifer.rollingInstanceIdentifer ?: @"nil"]));
            return;
        }

        // TODO: remove this check when we switch to reformed UA strings for the events api
        if (!self.preferences.legacyHostSDKVersion) {
            MMELog(MMELogInfo, MMEDebugEventTypeTurnstileFailed, ([NSString stringWithFormat:@"No host SDK version set - can not send turntile event, instance: %@",
                self.uniqueIdentifer.rollingInstanceIdentifer ?: @"nil"]));
            return;
        }

        NSDictionary *turnstileEventAttributes = @{
            MMEEventKeyEvent: MMEEventTypeAppUserTurnstile,
            MMEEventKeyCreated: [MMEDate.iso8601DateFormatter stringFromDate:[NSDate date]],
            MMEEventKeyVendorId: NSProcessInfo.mme_vendorId,
            MMEEventKeyDevice: NSProcessInfo.mme_deviceModel, // MMEEventKeyDevice is synonomous with MMEEventKeyModel but the server will only accept "device" in turnstile events
            MMEEventKeyOperatingSystem: NSProcessInfo.mme_osVersion,
            MMEEventSDKIdentifier: self.preferences.legacyUserAgentBase,
            MMEEventSDKVersion: self.preferences.legacyHostSDKVersion,
            MMEEventKeyEnabledTelemetry: @(self.preferences.isCollectionEnabled),
            MMEEventKeyLocationEnabled: @(CLLocationManager.locationServicesEnabled),
            MMEEventKeyLocationAuthorization: CLLocationManager.mme_authorizationStatusString,
            MMEEventKeySkuId: self.skuId ?: NSNull.null
       };

        MMEEvent *turnstileEvent = [MMEEvent turnstileEventWithAttributes:turnstileEventAttributes];
        
        MMELog(MMELogInfo, MMEDebugEventTypeTurnstile, ([NSString stringWithFormat:@"Sending turnstile event: %@, instance: %@",
            turnstileEvent , self.uniqueIdentifer.rollingInstanceIdentifer ?: @"nil"]));

        __weak __typeof__(self) weakSelf = self;
        [self.apiClient postEvent:turnstileEvent completionHandler:^(NSError * _Nullable error) {
            @try {
                __strong __typeof__(weakSelf) strongSelf = weakSelf;
                if (strongSelf == nil) {
                    return;
                }

                if (error) {
                    MMELog(MMELogInfo, MMEDebugEventTypeTurnstileFailed, ([NSString stringWithFormat:@"Could not send turnstile event: %@, instance: %@",
                        [error localizedDescription] , strongSelf.uniqueIdentifer.rollingInstanceIdentifer ?: @"nil"]));
                    return;
                }

                [strongSelf updateNextTurnstileSendDate];
                
                MMELog(MMELogInfo, MMEDebugEventTypeTurnstile, ([NSString stringWithFormat:@"Sent turnstile event, instance: %@",
                    strongSelf.uniqueIdentifer.rollingInstanceIdentifer ?: @"nil"]));
            }
            @catch(NSException *except) {
                [self reportException:except];
            }
        }];
    }
    @catch(NSException *except) {
        [self reportException:except];
    }
}

- (void)sendPendingTelemetryMetricsEvent {
    MMEEvent *pendingMetricsEvent = [self.metricsManager loadPendingTelemetryMetricsEvent];

    if (pendingMetricsEvent) {

        __weak __typeof__(self) weakSelf = self;
        [self.apiClient postEvent:pendingMetricsEvent completionHandler:^(NSError * _Nullable error) {
            if (error) {
                [[weakSelf logger] logEvent:[MMEEvent debugEventWithError:error]];
                return;
            }

            MMELog(MMELogInfo, MMEDebugEventTypeTelemetryMetrics, ([NSString stringWithFormat:@"Sent pendingTelemetryMetrics event, instance: %@",
                [[weakSelf uniqueIdentifer] rollingInstanceIdentifer] ?: @"nil"]));
        }];
    }
}

- (void)sendTelemetryMetricsEvent {
    @try {
        MMEEvent *telemetryMetricsEvent = [self.metricsManager generateTelemetryMetricsEvent];
        
        MMELog(MMELogInfo, MMEDebugEventTypeTelemetryMetrics, ([NSString stringWithFormat:@"Sending telemetryMetrics event: %@, instance: %@",
            telemetryMetricsEvent, self.uniqueIdentifer.rollingInstanceIdentifer ?: @"nil"]));
        
        if (telemetryMetricsEvent) {

            __weak __typeof__(self) weakSelf = self;
            [self.apiClient postEvent:telemetryMetricsEvent completionHandler:^(NSError * _Nullable error) {
                [[weakSelf metricsManager] resetMetrics];
                if (error) {
                    MMELog(MMELogInfo, MMEDebugEventTypeTelemetryMetrics, ([NSString stringWithFormat:@"Could not send telemetryMetrics event: %@, instance: %@",
                        [error localizedDescription], [[weakSelf uniqueIdentifer] rollingInstanceIdentifer] ?: @"nil"]));
                    return;
                }
                MMELog(MMELogInfo, MMEDebugEventTypeTelemetryMetrics, ([NSString stringWithFormat:@"Sent telemetryMetrics event, instance: %@",
                    [[weakSelf uniqueIdentifer] rollingInstanceIdentifer] ?: @"nil"]));
            }];
        }
    }
    @catch(NSException *except) {
        [self reportException:except];
    }
}

- (void)postMetadata:(NSArray *)metadata filePaths:(NSArray *)filePaths completionHandler:(nullable void (^)(NSError * _Nullable error))completionHandler {
    [self.apiClient postMetadata:metadata filePaths:filePaths completionHandler:^(NSError * _Nullable error) {
        if (completionHandler) {
            completionHandler(error);
        }
    }];
}

- (BOOL)isDebugLoggingEnabled {
    return [self.logger isEnabled];
}

- (void)setDebugHandler:(void (^)(NSUInteger, NSString *, NSString *))handler {
    [self.logger setHandler:handler];
}

// MARK: - Error & Exception Reporting

- (MMEEvent *)reportError:(NSError *)eventsError {
    MMEEvent *errorEvent = nil;
    
    @try {
        if (self.delegate && [self.delegate respondsToSelector:@selector(eventsManager:didEncounterError:)]) {
            [self.delegate eventsManager:self didEncounterError:eventsError];
        }

        NSError *createError = nil;
        errorEvent = [MMEEvent errorEventReporting:eventsError error:&createError];

        if (errorEvent) {
            [self pushEvent:errorEvent];
        }
        else {
            [self.logger logEvent:[MMEEvent debugEventWithError:createError]];
        }
    }
    @catch(NSException *except) {
        [self reportException:except];
    }

    return errorEvent;
}

- (MMEEvent *)reportException:(NSException *)exception {
    NSError *exceptionalError = [NSError errorWithDomain:MMEErrorDomain code:MMEErrorException userInfo:@{
        NSLocalizedDescriptionKey: @"Exception Report",
        MMEErrorUnderlyingExceptionKey: exception
    }];

    return [self reportError:exceptionalError];
}

// MARK: - Internal API

- (void)pauseMetricsCollection {
    MMELog(MMELogInfo, MMEDebugEventTypeMetricCollection, ([NSString stringWithFormat:@"Pausing metrics collection..., instance: %@",
        self.uniqueIdentifer.rollingInstanceIdentifer ?: @"nil"]));

    if (self.isPaused) {
        MMELog(MMELogInfo, MMEDebugEventTypeMetricCollection, ([NSString stringWithFormat:@"Already paused, instance: %@",
            self.uniqueIdentifer.rollingInstanceIdentifer ?: @"nil"]));
        return;
    }
    
    self.paused = YES;
    [self resetEventQueuing];
    
    [self.locationManager stopUpdatingLocation];

    MMELog(MMELogInfo, MMEDebugEventTypeLocationManager, ([NSString stringWithFormat:@"Paused and location manager stopped, instance: %@",
        self.uniqueIdentifer.rollingInstanceIdentifer ?: @"nil"]));
}

- (void)resumeMetricsCollection {
    MMELog(MMELogInfo, MMEDebugEventTypeMetricCollection, ([NSString stringWithFormat:@"Resuming metrics collection..., instance: %@",
        self.uniqueIdentifer.rollingInstanceIdentifer ?: @"nil"]));

    if (!self.isPaused || !self.preferences.isCollectionEnabled) {
        MMELog(MMELogInfo, MMEDebugEventTypeMetricCollection, ([NSString stringWithFormat:@"Already running, instance: %@",
            self.uniqueIdentifer.rollingInstanceIdentifer ?: @"nil"]));
        return;
    }
    
    self.paused = NO;

    if (self.preferences.isCollectionEnabled) {
        [self.locationManager startUpdatingLocation];
    }
    MMELog(MMELogInfo, MMEDebugEventTypeLocationManager, ([NSString stringWithFormat:@"Resumed and location manager started, instance: %@",
        self.uniqueIdentifer.rollingInstanceIdentifer ?: @"nil"]));
}

- (void)updateNextTurnstileSendDate {
    // Find the start of tomorrow and use that as the next turnstile send date. The effect of this is that
    // turnstile events can be sent as much as once per calendar day and always at the start of a session
    // when a map load happens.
    self.nextTurnstileSendDate = [NSDate.date mme_startOfTomorrow];

    MMELog(MMELogInfo, MMEDebugEventTypeTurnstile, ([NSString stringWithFormat:@"Set next turnstile date to: %@, instance: %@",
        self.nextTurnstileSendDate, self.uniqueIdentifer.rollingInstanceIdentifer ?: @"nil"]));
}

- (void)enqueueEvent:(MMEEvent *)event {
    if (!event) {
        return;
    }
    
    [self.eventQueue addObject:event];

    MMELog(MMELogInfo, MMEDebugEventTypePush, ([NSString stringWithFormat:@"Added event to event queue; event queue now has %ld events, instance: %@",
        (long)self.eventQueue.count, self.uniqueIdentifer.rollingInstanceIdentifer ?: @"nil"]));

    if (self.eventQueue.count >= self.preferences.eventFlushCount) {
        [self flush];
    }
    
    if (self.eventQueue.count == 1) {
        if (!self.queueTimer || !self.queueTimer.valid) {
            self.queueTimer = [NSTimer
                scheduledTimerWithTimeInterval:self.preferences.eventFlushInterval
                target:self
                selector:@selector(flush)
                userInfo:nil
                repeats:YES];
        }
    }
    
    if (self.delegate && [self.delegate respondsToSelector:@selector(eventsManager:didEnqueueEvent:)]) {
        [self.delegate eventsManager:self didEnqueueEvent:event];
    }
}

// MARK: - Deperecated API

- (void)initializeWithAccessToken:(NSString *)accessToken userAgentBase:(NSString *)userAgentBase hostSDKVersion:(NSString *)hostSDKVersion {
    [self startEventsManagerWithToken:accessToken userAgentBase:userAgentBase hostSDKVersion:hostSDKVersion];
}

- (void)pushEvent:(MMEEvent *)event {
    [self enqueueEvent:event];
}

- (void)flush {
    [self flushEventsManager];
}

// only called from MME_DEPRECATED methods
- (void)createAndPushEventBasedOnName:(NSString *)name attributes:(NSDictionary *)attributes {
    MMEDate *now = [MMEDate date];
    MMEEvent *event = nil;

    if ([name isEqualToString:MMEEventTypeMapLoad]) {
        event = [MMEEvent mapLoadEventWithDateString:[MMEDate.iso8601DateFormatter stringFromDate:now] commonEventData:nil];
    } else if ([name isEqualToString:MMEEventTypeMapTap]) {
        event = [MMEEvent mapTapEventWithDateString:[MMEDate.iso8601DateFormatter stringFromDate:now] attributes:attributes];
    } else if ([name isEqualToString:MMEEventTypeMapDragEnd]) {
        event = [MMEEvent mapDragEndEventWithDateString:[MMEDate.iso8601DateFormatter stringFromDate:now] attributes:attributes];
    } else if ([name isEqualToString:MMEventTypeOfflineDownloadStart]) {
        event = [MMEEvent mapOfflineDownloadStartEventWithDateString:[MMEDate.iso8601DateFormatter stringFromDate:now] attributes:attributes];
    } else if ([name isEqualToString:MMEventTypeOfflineDownloadEnd]) {
        event = [MMEEvent mapOfflineDownloadEndEventWithDateString:[MMEDate.iso8601DateFormatter stringFromDate:now] attributes:attributes];
    }
    
    if ([name hasPrefix:MMENavigationEventPrefix]) {
        event = [MMEEvent navigationEventWithName:name attributes:attributes];
    }

    if ([name hasPrefix:MMEVisionEventPrefix]) {
        event = [MMEEvent visionEventWithName:name attributes:attributes];
    }
    
    if ([name hasPrefix:MMESearchEventPrefix]) {
        event = [MMEEvent searchEventWithName:name attributes:attributes];
    }

    if (event) {
        #if DEBUG
        [self.logger pushDebugEventWithAttributes:@{
            @"instance": self.uniqueIdentifer.rollingInstanceIdentifer ?: @"nil",
            MMEDebugEventType: MMEDebugEventTypePush,
            MMEEventKeyLocalDebugDescription: [NSString stringWithFormat:@"Pushing event: %@", event]}];
        #endif
        [self pushEvent:event];
    } else {
        event = [MMEEvent eventWithDateString:[MMEDate.iso8601DateFormatter stringFromDate:now] name:name attributes:attributes];
        #if DEBUG
        [self.logger pushDebugEventWithAttributes:@{
            @"instance": self.uniqueIdentifer.rollingInstanceIdentifer ?: @"nil",
            MMEDebugEventType: MMEDebugEventTypePush,
            MMEEventKeyLocalDebugDescription: [NSString stringWithFormat:@"Pushing generic event: %@", event]}];
        #endif
        [self pushEvent:event];
    }
}

- (void)enqueueEventWithName:(NSString *)name {
    [self createAndPushEventBasedOnName:name attributes:@{}];
}

- (void)enqueueEventWithName:(NSString *)name attributes:(MMEMapboxEventAttributes *)attributes {
    [self createAndPushEventBasedOnName:name attributes:attributes];
}

- (void)disableLocationMetrics {
    @try {
        self.preferences.isCollectionEnabled = NO;
        [self.locationManager stopUpdatingLocation];
    }
    @catch (NSException *except) {
        [self reportException:except];
    }
}

// MARK: - MMELocationManagerDelegate

- (void)locationManager:(MMELocationManager *)locationManager didUpdateLocations:(NSArray *)locations {
    MMELog(MMELogInfo, MMEDebugEventTypeLocationManager, ([NSString stringWithFormat:@"Location manager sent %ld locations, instance: %@",
        (long)locations.count, self.uniqueIdentifer.rollingInstanceIdentifer ?: @"nil"]));
    
    for (CLLocation *location in locations) {
        MMEMutableMapboxEventAttributes *eventAttributes = [[MMEMutableMapboxEventAttributes alloc] init];
        
        [eventAttributes addEntriesFromDictionary:@{
            MMEEventKeyCreated: [MMEDate.iso8601DateFormatter stringFromDate:[location timestamp]],
            MMEEventKeyLatitude: @([location mme_latitudeRoundedWithPrecision:7]),
            MMEEventKeyLongitude: @([location mme_longitudeRoundedWithPrecision:7]),
            MMEEventKeyAltitude: @([location mme_roundedAltitude]),
            MMEEventHorizontalAccuracy: @([location mme_roundedHorizontalAccuracy]),
            MMEEventKeyVerticalAccuracy: @([location mme_roundedVerticalAccuracy]),
            MMEEventKeySpeed: @([location mme_roundedSpeed]),
            MMEEventKeyCourse: @([location mme_roundedCourse])
        }];
        
        if ([location floor]) {
            [eventAttributes setValue:@([location floor].level) forKey:MMEEventKeyFloor];
        }

        [self pushEvent:[MMEEvent locationEventWithAttributes:eventAttributes
                                            instanceIdentifer:self.uniqueIdentifer.rollingInstanceIdentifer
                                              commonEventData:nil]];
    }

    if ([self.delegate respondsToSelector:@selector(eventsManager:didUpdateLocations:)]) {
        [self.delegate eventsManager:self didUpdateLocations:locations];
    }
}

- (void)locationManagerDidStartLocationUpdates:(MMELocationManager *)locationManager {
    MMELog(MMELogInfo, MMEDebugEventTypeLocationManager, ([NSString stringWithFormat:@"Location manager started location updates, instance: %@",
        self.uniqueIdentifer.rollingInstanceIdentifer ?: @"nil"]));
}

- (void)locationManagerBackgroundLocationUpdatesDidTimeout:(MMELocationManager *)locationManager {
    MMELog(MMELogInfo, MMEDebugEventTypeLocationManager, ([NSString stringWithFormat:@"Location manager timed out, instance: %@",
        self.uniqueIdentifer.rollingInstanceIdentifer ?: @"nil"]));
}

- (void)locationManagerBackgroundLocationUpdatesDidAutomaticallyPause:(MMELocationManager *)locationManager {
    MMELog(MMELogInfo, MMEDebugEventTypeLocationManager, ([NSString stringWithFormat:@"Location manager automatically paused, instance: %@",
        self.uniqueIdentifer.rollingInstanceIdentifer ?: @"nil"]));
}

- (void)locationManagerDidStopLocationUpdates:(MMELocationManager *)locationManager {
    MMELog(MMELogInfo, MMEDebugEventTypeLocationManager, ([NSString stringWithFormat:@"Location manager stopped location updates, instance: %@",
        self.uniqueIdentifer.rollingInstanceIdentifer ?: @"nil"]));
}

- (void)locationManager:(MMELocationManager *)locationManager didVisit:(CLVisit *)visit {
    MMELog(MMELogInfo, MMEDebugEventTypeLocationManager, ([NSString stringWithFormat:@"Location manager visit %@, instance: %@",
        visit, self.uniqueIdentifer.rollingInstanceIdentifer ?: @"nil"]));
    
    CLLocation *location = [[CLLocation alloc] initWithLatitude:visit.coordinate.latitude longitude:visit.coordinate.longitude];
    
    MMEMutableMapboxEventAttributes *eventAttributes = [[MMEMutableMapboxEventAttributes alloc] init];
    
    [eventAttributes addEntriesFromDictionary:@{
        MMEEventKeyCreated: [MMEDate.iso8601DateFormatter stringFromDate:[location timestamp]],
        MMEEventKeyLatitude: @([location mme_latitudeRoundedWithPrecision:7]),
        MMEEventKeyLongitude: @([location mme_longitudeRoundedWithPrecision:7]),
        MMEEventHorizontalAccuracy: @(visit.horizontalAccuracy),
        MMEEventKeyVerticalAccuracy: @([location mme_roundedVerticalAccuracy]),
        MMEEventKeyArrivalDate: [MMEDate.iso8601DateFormatter stringFromDate:visit.arrivalDate],
        MMEEventKeyDepartureDate: [MMEDate.iso8601DateFormatter stringFromDate:visit.departureDate]
    }];
    
    if ([location floor]) {
        [eventAttributes setValue:@([location floor].level) forKey:MMEEventKeyFloor];
    }

    [self pushEvent:[MMEEvent visitEventWithAttributes:eventAttributes]];

    if ([self.delegate respondsToSelector:@selector(eventsManager:didVisit:)]) {
        [self.delegate eventsManager:self didVisit:visit];
    }
}

- (void)registerOnURLResponseListener:(OnURLResponse)onURLResponse {
    [self.urlResponseListeners addObject:[onURLResponse copy]];
}

- (void)registerOnSerializationErrorListener:(OnSerializationError)onSerializationError {
    [self.serializationErrorListeners addObject:[onSerializationError copy]];
}

@end

NS_ASSUME_NONNULL_END
