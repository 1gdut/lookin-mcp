#import "LKXBridgeService.h"

#import "Lookin_PTChannel.h"
#import "Lookin_PTUSBHub.h"
#import "Lookin_PTProtocol.h"
#import "LookinDefines.h"
#import "LookinConnectionAttachment.h"
#import "LookinConnectionResponseAttachment.h"
#import "LookinHierarchyInfo.h"
#import "LookinDisplayItem.h"
#import "LookinDisplayItemDetail.h"
#import "LookinAppInfo.h"
#import "LookinObject.h"
#import "LookinStaticAsyncUpdateTask.h"
#import "LookinAttributesGroup.h"
#import "LookinAttributesSection.h"
#import "LookinAttribute.h"
#import "LookinAutoLayoutConstraint.h"
#import "LookinTuple.h"
#import "Color+Lookin.h"
#import "Image+Lookin.h"

static NSString * const LKXTransportSimulator = @"simulator";
static NSString * const LKXTransportUSB = @"usb";
static NSString * const LKXTransportCoreDevice = @"coredevice";
static NSString * const LKXClientVersion = @"1.0.7";
static NSString * const LKXScreenshotModeNone = @"none";
static NSString * const LKXScreenshotModeGroup = @"group";
static NSString * const LKXScreenshotModeSolo = @"solo";
static NSString * const LKXHierarchyFrameMatchExact = @"exact";
static NSString * const LKXHierarchyFrameMatchIntersects = @"intersects";
static NSString * const LKXHierarchyFrameMatchContains = @"contains";
static const NSInteger LKXConnectRetryCount = 4;
static const NSTimeInterval LKXConnectRetryDelay = 0.25;
static const NSTimeInterval LKXDisconnectDrainDelay = 0.25;
static NSString * const LKXStateStoreDirectoryName = @"lookinextension-state";
static NSString * const LKXStateStoreFileName = @"session-store.json";

@interface LKXBridgeTarget : NSObject
@property(nonatomic, copy) NSString *targetID;
@property(nonatomic, copy) NSString *transport;
@property(nonatomic, assign) int port;
@property(nonatomic, strong, nullable) NSNumber *deviceID;
@property(nonatomic, copy, nullable) NSString *deviceIdentifier;
@property(nonatomic, copy, nullable) NSString *deviceUDID;
@property(nonatomic, copy, nullable) NSString *hostAddress;
@property(nonatomic, copy, nullable) NSString *hostname;
@end

@implementation LKXBridgeTarget
@end

@interface LKXPendingRequest : NSObject
@property(nonatomic, assign) uint32_t tag;
@property(nonatomic, assign) uint32_t requestType;
@property(nonatomic, weak) Lookin_PTChannel *channel;
@property(nonatomic, copy) void (^completion)(LookinConnectionResponseAttachment * _Nullable response, NSError * _Nullable error);
@end

@implementation LKXPendingRequest
@end

@interface LKXBridgeService () <Lookin_PTChannelDelegate>
@property(nonatomic, strong) dispatch_queue_t protocolQueue;
@property(nonatomic, strong) Lookin_PTProtocol *protocol;
@property(nonatomic, strong) NSMutableDictionary<NSString *, LKXPendingRequest *> *pendingRequests;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, dispatch_block_t> *disconnectWaiters;
@property(nonatomic, strong) NSMutableDictionary<NSString *, Lookin_PTChannel *> *connectedChannels;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSArray<NSDictionary *> *> *cachedFlatNodesByTargetID;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *coreDeviceRecordsByIdentifier;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSMutableDictionary *> *sessionsByID;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSMutableDictionary *> *snapshotsByID;
@property(nonatomic, strong) NSMutableArray<id> *notificationObservers;
@end

@implementation LKXBridgeService

- (instancetype)init {
    if (self = [super init]) {
        _protocolQueue = dispatch_queue_create("lookinextension.bridge.protocol", DISPATCH_QUEUE_SERIAL);
        _protocol = [Lookin_PTProtocol sharedProtocolForQueue:_protocolQueue];
        _pendingRequests = [NSMutableDictionary dictionary];
        _disconnectWaiters = [NSMutableDictionary dictionary];
        _connectedChannels = [NSMutableDictionary dictionary];
        _cachedFlatNodesByTargetID = [NSMutableDictionary dictionary];
        _coreDeviceRecordsByIdentifier = [NSMutableDictionary dictionary];
        _sessionsByID = [NSMutableDictionary dictionary];
        _snapshotsByID = [NSMutableDictionary dictionary];
        _notificationObservers = [NSMutableArray array];
        [self _loadStateStoreIntoMemory];
    }
    return self;
}

- (void)dealloc {
    for (Lookin_PTChannel *channel in self.connectedChannels.allValues) {
        [channel cancel];
    }

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    for (id observer in self.notificationObservers) {
        [center removeObserver:observer];
    }
}

- (void)listTargetsWithCompletion:(void (^)(NSArray<NSDictionary *> * _Nullable, NSError * _Nullable))completion {
    dispatch_group_t group = dispatch_group_create();
    NSMutableArray<LKXBridgeTarget *> *candidates = [NSMutableArray array];

    for (int port = LookinSimulatorIPv4PortNumberStart; port <= LookinSimulatorIPv4PortNumberEnd; port++) {
        LKXBridgeTarget *target = [LKXBridgeTarget new];
        target.transport = LKXTransportSimulator;
        target.port = port;
        target.targetID = [self _targetIDForTransport:target.transport port:port deviceID:nil deviceIdentifier:nil];
        [candidates addObject:target];
    }

    dispatch_group_enter(group);
    [self _discoverUSBTargetsWithCompletion:^(NSArray<LKXBridgeTarget *> *targets, NSError *error) {
        if (!error && targets.count) {
            [candidates addObjectsFromArray:targets];
        }
        dispatch_group_leave(group);
    }];

    dispatch_group_enter(group);
    [self _discoverCoreDeviceTargetsWithCompletion:^(NSArray<LKXBridgeTarget *> *targets, NSError *error) {
        if (!error && targets.count) {
            [candidates addObjectsFromArray:targets];
        }
        dispatch_group_leave(group);
    }];

    dispatch_group_notify(group, self.protocolQueue, ^{
        NSMutableDictionary<NSString *, LKXBridgeTarget *> *dedupedByTargetID = [NSMutableDictionary dictionary];
        for (LKXBridgeTarget *target in candidates) {
            if (target.targetID.length > 0 && !dedupedByTargetID[target.targetID]) {
                dedupedByTargetID[target.targetID] = target;
            }
        }

        NSArray<LKXBridgeTarget *> *allCandidates = dedupedByTargetID.allValues;
        if (!allCandidates.count) {
            completion(@[], nil);
            return;
        }

        dispatch_group_t probeGroup = dispatch_group_create();
        NSMutableArray<NSDictionary *> *results = [NSMutableArray array];
        for (LKXBridgeTarget *target in allCandidates) {
            dispatch_group_enter(probeGroup);
            [self _probeTarget:target completion:^(NSDictionary * _Nullable result, NSError * _Nullable error) {
                if (result) {
                    @synchronized (results) {
                        [results addObject:result];
                    }
                }
                dispatch_group_leave(probeGroup);
            }];
        }

        dispatch_group_notify(probeGroup, self.protocolQueue, ^{
            NSArray<NSDictionary *> *sorted = [results sortedArrayUsingDescriptors:@[
                [NSSortDescriptor sortDescriptorWithKey:@"transport" ascending:YES],
                [NSSortDescriptor sortDescriptorWithKey:@"port" ascending:YES]
            ]];
            completion(sorted, nil);
        });
    });
}

- (void)listSessionsWithCompletion:(void (^)(NSArray<NSDictionary *> * _Nullable, NSError * _Nullable))completion {
    NSMutableArray<NSDictionary *> *sessions = [NSMutableArray array];
    NSArray<NSString *> *sortedSessionIDs = [[self.sessionsByID allKeys] sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
    for (NSString *sessionID in sortedSessionIDs) {
        NSDictionary *record = [self _sanitizedSessionRecord:self.sessionsByID[sessionID]];
        if (record) {
            [sessions addObject:record];
        }
    }
    completion(sessions, nil);
}

- (void)createSessionForTarget:(NSString *)targetID completion:(void (^)(NSDictionary * _Nullable, NSError * _Nullable))completion {
    LKXBridgeTarget *target = [self _parseTargetID:targetID];
    if (!target) {
        completion(nil, [self _bridgeErrorWithCode:@"target_not_found" message:@"Invalid target identifier."]);
        return;
    }

    NSString *timestamp = [self _timestampStringForNow];
    NSString *sessionID = NSUUID.UUID.UUIDString;
    NSMutableDictionary *record = [@{
        @"session_id": sessionID,
        @"target_id": target.targetID ?: @"",
        @"created_at": timestamp,
        @"updated_at": timestamp,
        @"snapshot_ids": [NSMutableArray array]
    } mutableCopy];
    self.sessionsByID[sessionID] = record;
    [self _persistStateStore];
    completion([self _sanitizedSessionRecord:record], nil);
}

- (void)deleteSession:(NSString *)sessionID completion:(void (^)(NSDictionary * _Nullable, NSError * _Nullable))completion {
    NSMutableDictionary *session = [self _sessionRecordForID:sessionID];
    if (!session) {
        completion(nil, [self _bridgeErrorWithCode:@"session_not_found" message:@"Unknown session identifier."]);
        return;
    }

    NSArray *snapshotIDs = [[session[@"snapshot_ids"] isKindOfClass:[NSArray class]] ? session[@"snapshot_ids"] : @[] copy];
    for (NSString *snapshotID in snapshotIDs) {
        [self.snapshotsByID removeObjectForKey:snapshotID];
    }
    [self.sessionsByID removeObjectForKey:sessionID];
    [self _persistStateStore];
    completion(@{
        @"session_id": sessionID,
        @"deleted_snapshot_count": @(snapshotIDs.count)
    }, nil);
}

- (void)listSnapshotsForSession:(NSString * _Nullable)sessionID completion:(void (^)(NSArray<NSDictionary *> * _Nullable, NSError * _Nullable))completion {
    NSMutableArray<NSDictionary *> *snapshots = [NSMutableArray array];
    if (sessionID.length > 0) {
        NSMutableDictionary *session = [self _sessionRecordForID:sessionID];
        if (!session) {
            completion(nil, [self _bridgeErrorWithCode:@"session_not_found" message:@"Unknown session identifier."]);
            return;
        }
        for (NSString *snapshotID in [session[@"snapshot_ids"] isKindOfClass:[NSArray class]] ? session[@"snapshot_ids"] : @[]) {
            NSDictionary *snapshot = [self _sanitizedSnapshotRecord:self.snapshotsByID[snapshotID]];
            if (snapshot) {
                [snapshots addObject:snapshot];
            }
        }
    } else {
        NSArray<NSString *> *sortedSnapshotIDs = [[self.snapshotsByID allKeys] sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
        for (NSString *snapshotID in sortedSnapshotIDs) {
            NSDictionary *snapshot = [self _sanitizedSnapshotRecord:self.snapshotsByID[snapshotID]];
            if (snapshot) {
                [snapshots addObject:snapshot];
            }
        }
    }
    completion(snapshots, nil);
}

- (void)captureSnapshotForSession:(NSString *)sessionID
                             name:(NSString * _Nullable)name
                          options:(NSDictionary * _Nullable)options
                       completion:(void (^)(NSDictionary * _Nullable, NSError * _Nullable))completion {
    NSMutableDictionary *session = [self _sessionRecordForID:sessionID];
    if (!session) {
        completion(nil, [self _bridgeErrorWithCode:@"session_not_found" message:@"Unknown session identifier."]);
        return;
    }

    [self fetchHierarchyForTarget:nil sessionID:sessionID options:options completion:^(NSDictionary * _Nullable result, NSError * _Nullable error) {
        if (error) {
            completion(nil, error);
            return;
        }

        NSString *snapshotID = NSUUID.UUID.UUIDString;
        NSString *timestamp = [self _timestampStringForNow];
        NSMutableDictionary *snapshot = [@{
            @"snapshot_id": snapshotID,
            @"session_id": sessionID,
            @"target_id": session[@"target_id"] ?: @"",
            @"name": name ?: @"",
            @"created_at": timestamp,
            @"options": [self _normalizedHierarchyOptions:options] ?: @{},
            @"hierarchy": result ?: @{}
        } mutableCopy];
        self.snapshotsByID[snapshotID] = snapshot;

        NSMutableArray *snapshotIDs = [session[@"snapshot_ids"] isKindOfClass:[NSArray class]] ? [session[@"snapshot_ids"] mutableCopy] : [NSMutableArray array];
        [snapshotIDs addObject:snapshotID];
        session[@"snapshot_ids"] = snapshotIDs;
        session[@"updated_at"] = timestamp;

        [self _persistStateStore];
        completion([self _sanitizedSnapshotRecord:snapshot], nil);
    }];
}

- (void)diffSnapshotsForSession:(NSString *)sessionID
                      snapshotA:(NSString *)snapshotAID
                      snapshotB:(NSString *)snapshotBID
                     completion:(void (^)(NSDictionary * _Nullable, NSError * _Nullable))completion {
    NSMutableDictionary *session = [self _sessionRecordForID:sessionID];
    if (!session) {
        completion(nil, [self _bridgeErrorWithCode:@"session_not_found" message:@"Unknown session identifier."]);
        return;
    }

    NSDictionary *snapshotA = self.snapshotsByID[snapshotAID];
    NSDictionary *snapshotB = self.snapshotsByID[snapshotBID];
    if (!snapshotA || !snapshotB) {
        completion(nil, [self _bridgeErrorWithCode:@"snapshot_not_found" message:@"One or more snapshot identifiers are unknown."]);
        return;
    }
    if (![snapshotA[@"session_id"] isEqual:sessionID] || ![snapshotB[@"session_id"] isEqual:sessionID]) {
        completion(nil, [self _bridgeErrorWithCode:@"snapshot_mismatch" message:@"Snapshots must belong to the requested session."]);
        return;
    }

    completion([self _diffPayloadForSnapshot:snapshotA againstSnapshot:snapshotB session:session], nil);
}

- (void)pingTarget:(NSString *)targetID completion:(void (^)(NSDictionary * _Nullable, NSError * _Nullable))completion {
    [self pingTarget:targetID sessionID:nil completion:completion];
}

- (void)pingTarget:(NSString * _Nullable)targetID
         sessionID:(NSString * _Nullable)sessionID
        completion:(void (^)(NSDictionary * _Nullable, NSError * _Nullable))completion {
    LKXBridgeTarget *target = [self _resolveTargetWithTargetID:targetID sessionID:sessionID error:nil];
    if (!target) {
        NSError *error = nil;
        [self _resolveTargetWithTargetID:targetID sessionID:sessionID error:&error];
        completion(nil, error ?: [self _bridgeErrorWithCode:@"target_not_found" message:@"Invalid target or session identifier."]);
        return;
    }

    [self _connectToTarget:target completion:^(Lookin_PTChannel * _Nullable channel, NSError * _Nullable error) {
        if (error || !channel) {
            completion(nil, [self _connectionErrorForTarget:target underlyingError:error]);
            return;
        }

        [self _sendRequestType:LookinRequestTypePing data:nil channel:channel timeout:2 completion:^(LookinConnectionResponseAttachment * _Nullable response, NSError * _Nullable requestError) {
            NSDictionary *result = nil;
            NSError *finalError = requestError;
            if (!requestError && response) {
                NSError *versionError = [self _versionErrorForResponse:response];
                if (versionError) {
                    finalError = versionError;
                } else {
                    NSMutableDictionary *payload = [self _baseDictionaryForTarget:target];
                    payload[@"reachable"] = @YES;
                    payload[@"background"] = @(response.appIsInBackground);
                    payload[@"server_version"] = @(response.lookinServerVersion);
                    if (sessionID.length > 0) {
                        payload[@"session_id"] = sessionID;
                    }
                    result = payload;
                }
            }
            [self _finishChannel:channel result:result error:finalError completion:completion];
        }];
    }];
}

- (void)fetchHierarchyForTarget:(NSString *)targetID completion:(void (^)(NSDictionary * _Nullable, NSError * _Nullable))completion {
    [self fetchHierarchyForTarget:targetID sessionID:nil options:nil completion:completion];
}

- (void)findNodesForTarget:(NSString *)targetID
                     query:(NSDictionary *)query
                completion:(void (^)(NSDictionary * _Nullable, NSError * _Nullable))completion {
    [self findNodesForTarget:targetID sessionID:nil query:query completion:completion];
}

- (void)fetchObjectForTarget:(NSString *)targetID
                      nodeID:(unsigned long)nodeID
                  completion:(void (^)(NSDictionary * _Nullable, NSError * _Nullable))completion {
    [self fetchObjectForTarget:targetID sessionID:nil nodeID:nodeID completion:completion];
}

- (void)fetchViewDetailsForTarget:(NSString *)targetID
                           nodeID:(unsigned long)nodeID
                    screenshotMode:(NSString *)screenshotMode
                   includeSubitems:(BOOL)includeSubitems
                        completion:(void (^)(NSDictionary * _Nullable, NSError * _Nullable))completion {
    [self fetchViewDetailsForTarget:targetID sessionID:nil nodeID:nodeID screenshotMode:screenshotMode includeSubitems:includeSubitems completion:completion];
}

- (void)fetchScreenshotForTarget:(NSString *)targetID
                          nodeID:(NSNumber *)nodeID
                            mode:(NSString *)mode
                      completion:(void (^)(NSDictionary * _Nullable, NSError * _Nullable))completion {
    [self fetchScreenshotForTarget:targetID sessionID:nil nodeID:nodeID mode:mode completion:completion];
}

- (void)fetchHierarchyForTarget:(NSString * _Nullable)targetID
                      sessionID:(NSString * _Nullable)sessionID
                        options:(NSDictionary * _Nullable)options
                     completion:(void (^)(NSDictionary * _Nullable, NSError * _Nullable))completion {
    NSError *resolveError = nil;
    LKXBridgeTarget *target = [self _resolveTargetWithTargetID:targetID sessionID:sessionID error:&resolveError];
    if (!target) {
        completion(nil, resolveError ?: [self _bridgeErrorWithCode:@"target_not_found" message:@"Invalid target or session identifier."]);
        return;
    }

    NSDictionary *normalizedOptions = [self _normalizedHierarchyOptions:options];
    [self _connectToTarget:target completion:^(Lookin_PTChannel * _Nullable channel, NSError * _Nullable error) {
        if (error || !channel) {
            completion(nil, [self _connectionErrorForTarget:target underlyingError:error]);
            return;
        }

        [self _sendRequestType:LookinRequestTypePing data:nil channel:channel timeout:2 completion:^(LookinConnectionResponseAttachment * _Nullable pingResponse, NSError * _Nullable pingError) {
            if (pingError) {
                [self _finishChannel:channel result:nil error:pingError completion:completion];
                return;
            }
            if (pingResponse.appIsInBackground) {
                [self _finishChannel:channel result:nil error:[self _bridgeErrorWithCode:@"target_unresponsive" message:@"Target app is in background state."] completion:completion];
                return;
            }

            NSError *versionError = [self _versionErrorForResponse:pingResponse];
            if (versionError) {
                [self _finishChannel:channel result:nil error:versionError completion:completion];
                return;
            }

            NSDictionary *params = @{@"clientVersion": LKXClientVersion};
            [self _sendRequestType:LookinRequestTypeHierarchy data:params channel:channel timeout:5 completion:^(LookinConnectionResponseAttachment * _Nullable hierarchyResponse, NSError * _Nullable hierarchyError) {
                NSDictionary *result = nil;
                NSError *finalError = hierarchyError;
                if (!hierarchyError) {
                    if (hierarchyResponse.error) {
                        finalError = hierarchyResponse.error;
                    } else if (![hierarchyResponse.data isKindOfClass:[LookinHierarchyInfo class]]) {
                        finalError = [self _bridgeErrorWithCode:@"payload_decode_failed" message:@"Unexpected hierarchy payload."];
                    } else {
                        LookinHierarchyInfo *info = (LookinHierarchyInfo *)hierarchyResponse.data;
                        result = [self _dictionaryForHierarchyInfo:info target:target options:normalizedOptions];
                        if (sessionID.length > 0) {
                            NSMutableDictionary *mutableResult = [result mutableCopy];
                            mutableResult[@"session_id"] = sessionID;
                            result = mutableResult;
                        }
                    }
                }
                [self _finishChannel:channel result:result error:finalError completion:completion];
            }];
        }];
    }];
}

- (void)findNodesForTarget:(NSString * _Nullable)targetID
                  sessionID:(NSString * _Nullable)sessionID
                     query:(NSDictionary *)query
                completion:(void (^)(NSDictionary * _Nullable, NSError * _Nullable))completion {
    NSError *resolveError = nil;
    LKXBridgeTarget *target = [self _resolveTargetWithTargetID:targetID sessionID:sessionID error:&resolveError];
    if (!target) {
        completion(nil, resolveError ?: [self _bridgeErrorWithCode:@"target_not_found" message:@"Invalid target or session identifier."]);
        return;
    }

    [self _connectToTarget:target completion:^(Lookin_PTChannel * _Nullable channel, NSError * _Nullable error) {
        if (error || !channel) {
            completion(nil, [self _connectionErrorForTarget:target underlyingError:error]);
            return;
        }

        [self _validateChannel:channel target:target completion:^(NSError * _Nullable validationError) {
            if (validationError) {
                [self _finishChannel:channel result:nil error:validationError completion:completion];
                return;
            }

            NSDictionary *params = @{@"clientVersion": LKXClientVersion};
            [self _sendRequestType:LookinRequestTypeHierarchy data:params channel:channel timeout:8 completion:^(LookinConnectionResponseAttachment * _Nullable response, NSError * _Nullable requestError) {
                if (requestError) {
                    [self _finishChannel:channel result:nil error:requestError completion:completion];
                    return;
                }
                if (response.error) {
                    [self _finishChannel:channel result:nil error:response.error completion:completion];
                    return;
                }
                if (![response.data isKindOfClass:[LookinHierarchyInfo class]]) {
                    [self _finishChannel:channel result:nil error:[self _bridgeErrorWithCode:@"payload_decode_failed" message:@"Unexpected hierarchy payload."] completion:completion];
                    return;
                }

                LookinHierarchyInfo *info = (LookinHierarchyInfo *)response.data;
                NSDictionary *hierarchyPayload = [self _dictionaryForHierarchyInfo:info target:target options:nil];
                void (^finishWithRoots)(NSArray<NSDictionary *> *) = ^(NSArray<NSDictionary *> *roots) {
                    NSArray<NSDictionary *> *matches = [self _findMatchesInProjectedRoots:roots query:query];
                    NSMutableDictionary *payload = [self _baseDictionaryForTarget:target];
                    if (sessionID.length > 0) {
                        payload[@"session_id"] = sessionID;
                    }
                    payload[@"query"] = query ?: @{};
                    payload[@"match_count"] = @(matches.count);
                    payload[@"matches"] = matches;
                    [self _finishChannel:channel result:payload error:nil completion:completion];
                };

                if (![self _queryNeedsDetailEnrichment:query]) {
                    finishWithRoots([hierarchyPayload[@"roots"] isKindOfClass:[NSArray class]] ? hierarchyPayload[@"roots"] : @[]);
                    return;
                }

                [self _fetchSearchMetadataForHierarchyInfo:info channel:channel completion:^(NSDictionary<NSNumber *,NSDictionary *> * _Nullable metadataByDetailNodeID, NSError * _Nullable metadataError) {
                    if (metadataError) {
                        [self _finishChannel:channel result:nil error:metadataError completion:completion];
                        return;
                    }
                    NSArray<NSDictionary *> *roots = [hierarchyPayload[@"roots"] isKindOfClass:[NSArray class]] ? hierarchyPayload[@"roots"] : @[];
                    finishWithRoots([self _rootsByApplyingSearchMetadata:metadataByDetailNodeID ?: @{} toRoots:roots]);
                }];
            }];
        }];
    }];
}

- (void)fetchObjectForTarget:(NSString *)targetID
                   sessionID:(NSString * _Nullable)sessionID
                      nodeID:(unsigned long)nodeID
                  completion:(void (^)(NSDictionary * _Nullable, NSError * _Nullable))completion {
    if (nodeID == 0) {
        completion(nil, [self _bridgeErrorWithCode:@"invalid_arguments" message:@"node_id must be greater than 0."]);
        return;
    }

    NSError *resolveError = nil;
    LKXBridgeTarget *target = [self _resolveTargetWithTargetID:targetID sessionID:sessionID error:&resolveError];
    if (!target) {
        completion(nil, resolveError ?: [self _bridgeErrorWithCode:@"target_not_found" message:@"Invalid target or session identifier."]);
        return;
    }

    [self _connectToTarget:target completion:^(Lookin_PTChannel * _Nullable channel, NSError * _Nullable error) {
        if (error || !channel) {
            completion(nil, [self _connectionErrorForTarget:target underlyingError:error]);
            return;
        }

        [self _validateChannel:channel target:target completion:^(NSError * _Nullable validationError) {
            if (validationError) {
                [self _finishChannel:channel result:nil error:validationError completion:completion];
                return;
            }

            [self _sendRequestType:LookinRequestTypeFetchObject data:@(nodeID) channel:channel timeout:8 completion:^(LookinConnectionResponseAttachment * _Nullable response, NSError * _Nullable requestError) {
                NSDictionary *result = nil;
                NSError *finalError = requestError;
                if (!requestError) {
                    if (response.error) {
                        finalError = response.error;
                    } else if (![response.data isKindOfClass:[LookinObject class]]) {
                        finalError = [self _bridgeErrorWithCode:@"payload_decode_failed" message:@"Unexpected object payload."];
                    } else {
                        LookinObject *object = (LookinObject *)response.data;
                        NSMutableDictionary *payload = [self _baseDictionaryForTarget:target];
                        if (sessionID.length > 0) {
                            payload[@"session_id"] = sessionID;
                        }
                        payload[@"node_id"] = @(nodeID);
                        payload[@"object"] = [self _jsonValueFromObject:object] ?: @{};
                        result = payload;
                    }
                }
                [self _finishChannel:channel result:result error:finalError completion:completion];
            }];
        }];
    }];
}

- (void)fetchViewDetailsForTarget:(NSString *)targetID
                        sessionID:(NSString * _Nullable)sessionID
                           nodeID:(unsigned long)nodeID
                    screenshotMode:(NSString *)screenshotMode
                   includeSubitems:(BOOL)includeSubitems
                        completion:(void (^)(NSDictionary * _Nullable, NSError * _Nullable))completion {
    if (nodeID == 0) {
        completion(nil, [self _bridgeErrorWithCode:@"invalid_arguments" message:@"node_id must be greater than 0."]);
        return;
    }

    NSError *resolveError = nil;
    LKXBridgeTarget *target = [self _resolveTargetWithTargetID:targetID sessionID:sessionID error:&resolveError];
    if (!target) {
        completion(nil, resolveError ?: [self _bridgeErrorWithCode:@"target_not_found" message:@"Invalid target or session identifier."]);
        return;
    }

    [self _resolveDetailNodeIDForTarget:target requestedNodeID:nodeID completion:^(unsigned long resolvedNodeID, NSDictionary * _Nullable matchedNode, NSError * _Nullable resolveError) {
        if (resolveError) {
            completion(nil, resolveError);
            return;
        }

        [self _connectToTarget:target completion:^(Lookin_PTChannel * _Nullable channel, NSError * _Nullable error) {
        if (error || !channel) {
            completion(nil, [self _connectionErrorForTarget:target underlyingError:error]);
            return;
        }

        [self _validateChannel:channel target:target completion:^(NSError * _Nullable validationError) {
            if (validationError) {
                [self _finishChannel:channel result:nil error:validationError completion:completion];
                return;
            }

            LookinStaticAsyncUpdateTask *task = [LookinStaticAsyncUpdateTask new];
            task.oid = resolvedNodeID;
            task.clientReadableVersion = LKXClientVersion;
            task.attrRequest = LookinDetailUpdateTaskAttrRequest_Need;
            task.needBasisVisualInfo = YES;
            task.needSubitems = includeSubitems;
            task.taskType = [self _taskTypeForScreenshotMode:screenshotMode];

            LookinStaticAsyncUpdateTasksPackage *package = [LookinStaticAsyncUpdateTasksPackage new];
            package.tasks = @[task];

            [self _sendRequestType:LookinRequestTypeHierarchyDetails data:@[package] channel:channel timeout:15 completion:^(LookinConnectionResponseAttachment * _Nullable response, NSError * _Nullable requestError) {
                NSDictionary *result = nil;
                NSError *finalError = requestError;
                if (!requestError) {
                    if (response.error) {
                        finalError = response.error;
                    } else if (![response.data isKindOfClass:[NSArray class]]) {
                        finalError = [self _bridgeErrorWithCode:@"payload_decode_failed" message:@"Unexpected detail payload."];
                    } else {
                        NSArray *details = (NSArray *)response.data;
                        LookinDisplayItemDetail *detail = details.firstObject;
                        if (![detail isKindOfClass:[LookinDisplayItemDetail class]]) {
                            finalError = [self _bridgeErrorWithCode:@"payload_decode_failed" message:@"Missing detail payload."];
                        } else if (detail.failureCode == -1) {
                            finalError = [self _bridgeErrorWithCode:@"node_not_found" message:@"Failed to resolve target node in app runtime."];
                        } else {
                            NSMutableDictionary *payload = [[self _dictionaryForDetail:detail target:target screenshotMode:screenshotMode] mutableCopy];
                            [self _mergeMissingBasisVisualInfoIntoDetailPayload:payload fromMatchedNode:matchedNode];
                            if (sessionID.length > 0) {
                                payload[@"session_id"] = sessionID;
                            }
                            payload[@"requested_node_id"] = @(nodeID);
                            payload[@"resolved_node_id"] = @(resolvedNodeID);
                            if (matchedNode) {
                                payload[@"matched_node"] = matchedNode;
                            }
                            result = payload;
                        }
                    }
                }
                [self _finishChannel:channel result:result error:finalError completion:completion];
            }];
        }];
        }];
    }];
}

- (void)fetchScreenshotForTarget:(NSString *)targetID
                       sessionID:(NSString * _Nullable)sessionID
                          nodeID:(NSNumber *)nodeID
                            mode:(NSString *)mode
                      completion:(void (^)(NSDictionary * _Nullable, NSError * _Nullable))completion {
    NSError *resolveError = nil;
    LKXBridgeTarget *target = [self _resolveTargetWithTargetID:targetID sessionID:sessionID error:&resolveError];
    if (!target) {
        completion(nil, resolveError ?: [self _bridgeErrorWithCode:@"target_not_found" message:@"Invalid target or session identifier."]);
        return;
    }

    if (nodeID) {
        [self fetchViewDetailsForTarget:targetID sessionID:sessionID nodeID:nodeID.unsignedLongValue screenshotMode:(mode ?: LKXScreenshotModeGroup) includeSubitems:NO completion:^(NSDictionary * _Nullable result, NSError * _Nullable error) {
            if (error) {
                completion(nil, error);
                return;
            }
            NSDictionary *screenshot = result[@"screenshot"];
            if (!screenshot || screenshot == (id)[NSNull null]) {
                completion(nil, [self _bridgeErrorWithCode:@"screenshot_unavailable" message:@"No screenshot was returned for the target node."]);
                return;
            }
            NSMutableDictionary *payload = [self _baseDictionaryForTarget:target];
            if (sessionID.length > 0) {
                payload[@"session_id"] = sessionID;
            }
            payload[@"node_id"] = nodeID;
            payload[@"mode"] = mode ?: LKXScreenshotModeGroup;
            payload[@"screenshot"] = screenshot;
            completion(payload, nil);
        }];
        return;
    }

    [self _connectToTarget:target completion:^(Lookin_PTChannel * _Nullable channel, NSError * _Nullable error) {
        if (error || !channel) {
            completion(nil, [self _connectionErrorForTarget:target underlyingError:error]);
            return;
        }

        [self _validateChannel:channel target:target completion:^(NSError * _Nullable validationError) {
            if (validationError) {
                [self _finishChannel:channel result:nil error:validationError completion:completion];
                return;
            }

            NSDictionary *params = @{@"needImages": @YES};
            [self _sendRequestType:LookinRequestTypeApp data:params channel:channel timeout:8 completion:^(LookinConnectionResponseAttachment * _Nullable response, NSError * _Nullable requestError) {
                NSDictionary *result = nil;
                NSError *finalError = requestError;
                if (!requestError) {
                    if (response.error) {
                        finalError = response.error;
                    } else if (![response.data isKindOfClass:[LookinAppInfo class]]) {
                        finalError = [self _bridgeErrorWithCode:@"payload_decode_failed" message:@"Unexpected app info payload."];
                    } else {
                        LookinAppInfo *info = (LookinAppInfo *)response.data;
                        NSDictionary *shot = [self _persistImage:info.screenshot prefix:@"app"];
                        if (!shot) {
                            finalError = [self _bridgeErrorWithCode:@"screenshot_unavailable" message:@"App screenshot is unavailable."];
                        } else {
                            NSMutableDictionary *payload = [self _baseDictionaryForTarget:target];
                            if (sessionID.length > 0) {
                                payload[@"session_id"] = sessionID;
                            }
                            payload[@"mode"] = @"app";
                            payload[@"screenshot"] = shot;
                            payload[@"app"] = [self _dictionaryForAppInfo:info];
                            result = payload;
                        }
                    }
                }
                [self _finishChannel:channel result:result error:finalError completion:completion];
            }];
        }];
    }];
}

#pragma mark - Discovery

- (void)_discoverCoreDeviceTargetsWithCompletion:(void (^)(NSArray<LKXBridgeTarget *> *targets, NSError * _Nullable error))completion {
    NSError *error = nil;
    [self.coreDeviceRecordsByIdentifier removeAllObjects];
    NSDictionary<NSString *, NSDictionary *> *recordsByIdentifier = [self _loadCoreDeviceRecordsByIdentifier:&error];
    if (error) {
        completion(@[], error);
        return;
    }

    NSMutableArray<LKXBridgeTarget *> *targets = [NSMutableArray array];
    for (NSDictionary *record in recordsByIdentifier.allValues) {
        LKXBridgeTarget *sampleTarget = [self _coreDeviceTargetFromRecord:record port:LookinUSBDeviceIPv4PortNumberStart];
        if (!sampleTarget) {
            continue;
        }

        for (int port = LookinUSBDeviceIPv4PortNumberStart; port <= LookinUSBDeviceIPv4PortNumberEnd; port++) {
            LKXBridgeTarget *target = [self _coreDeviceTargetFromRecord:record port:port];
            if (target) {
                [targets addObject:target];
            }
        }
    }

    completion(targets, nil);
}

- (NSDictionary<NSString *, NSDictionary *> *)_loadCoreDeviceRecordsByIdentifier:(NSError * _Nullable __autoreleasing *)error {
    if (self.coreDeviceRecordsByIdentifier.count > 0) {
        return [self.coreDeviceRecordsByIdentifier copy];
    }

    NSDictionary *payload = [self _runDevicectlJSONCommandWithArguments:@[@"list", @"devices"] error:error];
    NSArray<NSDictionary *> *devices = [payload[@"result"][@"devices"] isKindOfClass:[NSArray class]] ? payload[@"result"][@"devices"] : nil;
    if (!devices) {
        if (error) {
            *error = [self _bridgeErrorWithCode:@"coredevice_invalid_payload" message:@"CoreDevice returned an unexpected device list payload."];
        }
        return @{};
    }

    [self.coreDeviceRecordsByIdentifier removeAllObjects];
    for (NSDictionary *record in devices) {
        NSString *identifier = [record[@"identifier"] isKindOfClass:[NSString class]] ? record[@"identifier"] : nil;
        if (identifier.length > 0) {
            self.coreDeviceRecordsByIdentifier[identifier] = record;
        }
    }
    return [self.coreDeviceRecordsByIdentifier copy];
}

- (NSDictionary * _Nullable)_runDevicectlJSONCommandWithArguments:(NSArray<NSString *> *)arguments
                                                            error:(NSError * _Nullable __autoreleasing *)error {
    NSString *jsonPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"lookin-coredevice-%@.json", NSUUID.UUID.UUIDString]];
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/xcrun"];

    NSMutableArray<NSString *> *allArguments = [NSMutableArray arrayWithObject:@"devicectl"];
    [allArguments addObject:@"-j"];
    [allArguments addObject:jsonPath];
    [allArguments addObjectsFromArray:arguments];
    task.arguments = allArguments;

    task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    NSPipe *stderrPipe = [NSPipe pipe];
    task.standardError = stderrPipe;

    @try {
        [task launch];
    } @catch (NSException *exception) {
        if (error) {
            *error = [self _bridgeErrorWithCode:@"coredevice_launch_failed" message:exception.reason ?: @"Failed to launch devicectl."];
        }
        return nil;
    }

    [task waitUntilExit];

    NSData *stderrData = [[stderrPipe fileHandleForReading] readDataToEndOfFile];
    NSString *stderrText = [[NSString alloc] initWithData:stderrData encoding:NSUTF8StringEncoding] ?: @"";

    NSData *jsonData = [NSData dataWithContentsOfFile:jsonPath];
    [[NSFileManager defaultManager] removeItemAtPath:jsonPath error:nil];

    if (task.terminationStatus != 0) {
        if (error) {
            NSString *message = stderrText.length > 0 ? stderrText : @"devicectl exited with a non-zero status.";
            *error = [self _bridgeErrorWithCode:@"coredevice_command_failed" message:message];
        }
        return nil;
    }

    if (!jsonData) {
        if (error) {
            *error = [self _bridgeErrorWithCode:@"coredevice_missing_json" message:@"devicectl did not produce a JSON output file."];
        }
        return nil;
    }

    NSError *jsonError = nil;
    id object = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&jsonError];
    if (jsonError || ![object isKindOfClass:[NSDictionary class]]) {
        if (error) {
            *error = [self _bridgeErrorWithCode:@"coredevice_json_decode_failed" message:jsonError.localizedDescription ?: @"Failed to decode devicectl JSON output."];
        }
        return nil;
    }

    return (NSDictionary *)object;
}

- (LKXBridgeTarget * _Nullable)_coreDeviceTargetFromRecord:(NSDictionary *)record port:(int)port {
    NSString *identifier = [record[@"identifier"] isKindOfClass:[NSString class]] ? record[@"identifier"] : nil;
    NSDictionary *connection = [record[@"connectionProperties"] isKindOfClass:[NSDictionary class]] ? record[@"connectionProperties"] : nil;
    NSDictionary *hardware = [record[@"hardwareProperties"] isKindOfClass:[NSDictionary class]] ? record[@"hardwareProperties"] : nil;
    if (identifier.length == 0 || port <= 0) {
        return nil;
    }

    NSString *hostAddress = [connection[@"tunnelIPAddress"] isKindOfClass:[NSString class]] ? connection[@"tunnelIPAddress"] : nil;
    NSArray<NSString *> *hostnames = [connection[@"localHostnames"] isKindOfClass:[NSArray class]] ? connection[@"localHostnames"] : nil;
    NSString *hostname = hostnames.firstObject;
    NSString *tunnelState = [connection[@"tunnelState"] isKindOfClass:[NSString class]] ? connection[@"tunnelState"] : nil;
    if (hostAddress.length == 0 && hostname.length == 0) {
        return nil;
    }
    if (tunnelState.length > 0 && ![tunnelState.lowercaseString isEqualToString:@"connected"]) {
        return nil;
    }

    LKXBridgeTarget *target = [LKXBridgeTarget new];
    target.transport = LKXTransportCoreDevice;
    target.port = port;
    target.deviceIdentifier = identifier;
    target.deviceUDID = [hardware[@"udid"] isKindOfClass:[NSString class]] ? hardware[@"udid"] : nil;
    target.hostAddress = hostAddress;
    target.hostname = hostname;
    target.targetID = [self _targetIDForTransport:target.transport port:port deviceID:nil deviceIdentifier:identifier];
    return target;
}

- (void)_discoverUSBTargetsWithCompletion:(void (^)(NSArray<LKXBridgeTarget *> *targets, NSError * _Nullable error))completion {
    NSMutableOrderedSet<NSNumber *> *deviceIDs = [NSMutableOrderedSet orderedSet];
    Lookin_PTUSBHub *hub = [Lookin_PTUSBHub new];
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];

    id attachObserver = [center addObserverForName:Lookin_PTUSBDeviceDidAttachNotification object:hub queue:nil usingBlock:^(NSNotification * _Nonnull note) {
        NSNumber *deviceID = note.userInfo[@"DeviceID"];
        if (deviceID) {
            [deviceIDs addObject:deviceID];
        }
    }];
    [self.notificationObservers addObject:attachObserver];

    [hub listenOnQueue:self.protocolQueue onStart:^(NSError *error) {
        if (error) {
            completion(@[], error);
            return;
        }

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), self.protocolQueue, ^{
            NSMutableArray<LKXBridgeTarget *> *targets = [NSMutableArray array];
            for (NSNumber *deviceID in deviceIDs) {
                for (int port = LookinUSBDeviceIPv4PortNumberStart; port <= LookinUSBDeviceIPv4PortNumberEnd; port++) {
                    LKXBridgeTarget *target = [LKXBridgeTarget new];
                    target.transport = LKXTransportUSB;
                    target.port = port;
                    target.deviceID = deviceID;
                    target.targetID = [self _targetIDForTransport:target.transport port:port deviceID:deviceID deviceIdentifier:nil];
                    [targets addObject:target];
                }
            }
            completion(targets, nil);
        });
    } onEnd:nil];
}

- (void)_probeTarget:(LKXBridgeTarget *)target completion:(void (^)(NSDictionary * _Nullable result, NSError * _Nullable error))completion {
    [self _connectToTarget:target completion:^(Lookin_PTChannel * _Nullable channel, NSError * _Nullable error) {
        if (error || !channel) {
            NSDictionary *failureResult = [self _probeFailureResultForTarget:target error:error];
            if (failureResult) {
                completion(failureResult, nil);
                return;
            }
            completion(nil, error);
            return;
        }

        [self _sendRequestType:LookinRequestTypePing data:nil channel:channel timeout:1 completion:^(LookinConnectionResponseAttachment * _Nullable response, NSError * _Nullable pingError) {
            if (pingError || !response) {
                [self _finishChannel:channel result:nil error:pingError completion:completion];
                return;
            }

            NSError *versionError = [self _versionErrorForResponse:response];
            if (versionError) {
                NSMutableDictionary *result = [self _baseDictionaryForTarget:target];
                result[@"state"] = @"protocol_mismatch";
                result[@"server_version"] = @(response.lookinServerVersion);
                result[@"error"] = versionError.localizedDescription ?: @"Protocol mismatch";
                [self _finishChannel:channel result:result error:nil completion:completion];
                return;
            }

            if (response.appIsInBackground) {
                NSMutableDictionary *result = [self _baseDictionaryForTarget:target];
                result[@"state"] = @"background";
                result[@"server_version"] = @(response.lookinServerVersion);
                [self _finishChannel:channel result:result error:nil completion:completion];
                return;
            }

            NSDictionary *params = @{@"needImages": @NO};
            [self _sendRequestType:LookinRequestTypeApp data:params channel:channel timeout:2 completion:^(LookinConnectionResponseAttachment * _Nullable appResponse, NSError * _Nullable appError) {
                NSDictionary *result = nil;
                if (!appError && [appResponse.data isKindOfClass:[LookinAppInfo class]]) {
                    LookinAppInfo *info = (LookinAppInfo *)appResponse.data;
                    NSMutableDictionary *payload = [self _baseDictionaryForTarget:target];
                    [payload addEntriesFromDictionary:[self _dictionaryForAppInfo:info]];
                    payload[@"state"] = @"active";
                    result = payload;
                }
                [self _finishChannel:channel result:result error:appError completion:completion];
            }];
        }];
    }];
}

- (NSDictionary * _Nullable)_probeFailureResultForTarget:(LKXBridgeTarget *)target error:(NSError * _Nullable)error {
    BOOL supportsDiagnosticFailureState = [target.transport isEqualToString:LKXTransportCoreDevice] || [target.transport isEqualToString:LKXTransportUSB];
    if (!supportsDiagnosticFailureState) {
        return nil;
    }

    NSString *bridgeCode = [error.userInfo[@"bridge_code"] isKindOfClass:[NSString class]] ? error.userInfo[@"bridge_code"] : nil;
    BOOL isConnectionRefused = [bridgeCode isEqualToString:@"connection_refused"];
    if (!isConnectionRefused && [error.domain isEqualToString:NSPOSIXErrorDomain] && error.code == ECONNREFUSED) {
        isConnectionRefused = YES;
    }
    if (!isConnectionRefused) {
        return nil;
    }

    NSMutableDictionary *payload = [self _baseDictionaryForTarget:target];
    payload[@"state"] = @"connection_refused";
    NSError *normalized = [self _connectionErrorForTarget:target underlyingError:error];
    payload[@"error"] = normalized.localizedDescription ?: error.localizedDescription ?: @"Connection refused";
    return payload;
}

#pragma mark - Transport

- (void)_validateChannel:(Lookin_PTChannel *)channel
                  target:(LKXBridgeTarget *)target
              completion:(void (^)(NSError * _Nullable error))completion {
    [self _sendRequestType:LookinRequestTypePing data:nil channel:channel timeout:2 completion:^(LookinConnectionResponseAttachment * _Nullable response, NSError * _Nullable requestError) {
        if (requestError) {
            completion(requestError);
            return;
        }
        if (response.appIsInBackground) {
            completion([self _bridgeErrorWithCode:@"target_unresponsive" message:@"Target app is in background state."]);
            return;
        }
        NSError *versionError = [self _versionErrorForResponse:response];
        completion(versionError);
    }];
}

- (void)_connectToTarget:(LKXBridgeTarget *)target completion:(void (^)(Lookin_PTChannel * _Nullable channel, NSError * _Nullable error))completion {
    [self _connectToTarget:target attemptsRemaining:LKXConnectRetryCount completion:completion];
}

- (void)_connectToTarget:(LKXBridgeTarget *)target
       attemptsRemaining:(NSInteger)attemptsRemaining
              completion:(void (^)(Lookin_PTChannel * _Nullable channel, NSError * _Nullable error))completion {
    if (self.persistentConnectionsEnabled) {
        Lookin_PTChannel *cachedChannel = self.connectedChannels[target.targetID];
        if (cachedChannel.isConnected) {
            completion(cachedChannel, nil);
            return;
        }
        if (cachedChannel) {
            [self.connectedChannels removeObjectForKey:target.targetID];
            [cachedChannel cancel];
        }
    }

    Lookin_PTChannel *channel = [[Lookin_PTChannel alloc] initWithProtocol:self.protocol delegate:self];
    channel.targetPort = target.port;

    void (^handleConnectionResult)(NSError * _Nullable) = ^(NSError * _Nullable error) {
        if (!error) {
            if (self.persistentConnectionsEnabled) {
                self.connectedChannels[target.targetID] = channel;
            }
            completion(channel, nil);
            return;
        }

        [channel cancel];
        if (attemptsRemaining <= 1 || ![self _shouldRetryConnectionError:error]) {
            completion(nil, error);
            return;
        }

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(LKXConnectRetryDelay * NSEC_PER_SEC)), self.protocolQueue, ^{
            [self _connectToTarget:target attemptsRemaining:(attemptsRemaining - 1) completion:completion];
        });
    };

    if ([target.transport isEqualToString:LKXTransportUSB]) {
        Lookin_PTUSBHub *hub = [Lookin_PTUSBHub sharedHub];
        [channel connectToPort:target.port overUSBHub:hub deviceID:target.deviceID callback:^(NSError *error) {
            handleConnectionResult(error);
        }];
    } else if ([target.transport isEqualToString:LKXTransportCoreDevice]) {
        NSString *host = target.hostAddress.length > 0 ? target.hostAddress : target.hostname;
        if (host.length == 0) {
            handleConnectionResult([self _bridgeErrorWithCode:@"target_not_found" message:@"Missing CoreDevice tunnel host."]);
            return;
        }
        [channel connectToPort:target.port host:host callback:^(NSError *error, Lookin_PTAddress *address) {
            handleConnectionResult(error);
        }];
    } else {
        [channel connectToPort:target.port IPv4Address:INADDR_LOOPBACK callback:^(NSError *error, Lookin_PTAddress *address) {
            handleConnectionResult(error);
        }];
    }
}

- (void)_finishChannel:(Lookin_PTChannel * _Nullable)channel
                result:(id _Nullable)result
                 error:(NSError * _Nullable)error
            completion:(void (^)(id _Nullable result, NSError * _Nullable error))completion {
    if (self.persistentConnectionsEnabled) {
        completion(result, error);
        return;
    }

    [self _disconnectChannel:channel completion:^{
        completion(result, error);
    }];
}

- (void)_disconnectChannel:(Lookin_PTChannel * _Nullable)channel completion:(dispatch_block_t)completion {
    if (!channel) {
        if (completion) {
            completion();
        }
        return;
    }

    NSNumber *channelKey = @(channel.uniqueID);
    __block BOOL finished = NO;
    void (^finishOnce)(void) = ^{
        if (finished) {
            return;
        }
        finished = YES;
        [self.disconnectWaiters removeObjectForKey:channelKey];
        if (completion) {
            completion();
        }
    };

    self.disconnectWaiters[channelKey] = [finishOnce copy];
    [channel cancel];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(LKXDisconnectDrainDelay * NSEC_PER_SEC)), self.protocolQueue, ^{
        finishOnce();
    });
}

- (void)_sendRequestType:(uint32_t)requestType
                    data:(id _Nullable)data
                 channel:(Lookin_PTChannel *)channel
                 timeout:(NSTimeInterval)timeout
              completion:(void (^)(LookinConnectionResponseAttachment * _Nullable response, NSError * _Nullable error))completion {
    LookinConnectionAttachment *attachment = [LookinConnectionAttachment new];
    attachment.data = data;

    NSError *archiveError = nil;
    NSData *payloadData = [NSKeyedArchiver archivedDataWithRootObject:attachment requiringSecureCoding:YES error:&archiveError];
    if (archiveError) {
        completion(nil, archiveError);
        return;
    }

    uint32_t tag = [self.protocol newTag];
    NSString *requestKey = [self _requestKeyForChannel:channel tag:tag];

    LKXPendingRequest *pending = [LKXPendingRequest new];
    pending.tag = tag;
    pending.requestType = requestType;
    pending.channel = channel;
    pending.completion = completion;
    self.pendingRequests[requestKey] = pending;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), self.protocolQueue, ^{
        LKXPendingRequest *stillPending = self.pendingRequests[requestKey];
        if (stillPending) {
            [self.pendingRequests removeObjectForKey:requestKey];
            stillPending.completion(nil, [self _bridgeErrorWithCode:@"request_timeout" message:@"Request timed out."]);
        }
    });

    [channel sendFrameOfType:requestType tag:tag withPayload:[payloadData createReferencingDispatchData] callback:^(NSError *error) {
        if (error) {
            LKXPendingRequest *stillPending = self.pendingRequests[requestKey];
            if (stillPending) {
                [self.pendingRequests removeObjectForKey:requestKey];
                stillPending.completion(nil, error);
            }
        }
    }];
}

#pragma mark - Lookin_PTChannelDelegate

- (void)ioFrameChannel:(Lookin_PTChannel *)channel didReceiveFrameOfType:(uint32_t)type tag:(uint32_t)tag payload:(Lookin_PTData *)payload {
    NSString *requestKey = [self _requestKeyForChannel:channel tag:tag];
    LKXPendingRequest *pending = self.pendingRequests[requestKey];
    if (!pending) {
        return;
    }

    NSError *decodeError = nil;
    NSData *data = [NSData dataWithContentsOfDispatchData:payload.dispatchData];
    id object = [NSKeyedUnarchiver unarchiveObjectWithData:data];
    if (decodeError) {
        [self.pendingRequests removeObjectForKey:requestKey];
        pending.completion(nil, decodeError);
        return;
    }

    if (![object isKindOfClass:[LookinConnectionResponseAttachment class]]) {
        [self.pendingRequests removeObjectForKey:requestKey];
        pending.completion(nil, [self _bridgeErrorWithCode:@"payload_decode_failed" message:@"Unexpected response payload."]);
        return;
    }

    LookinConnectionResponseAttachment *response = (LookinConnectionResponseAttachment *)object;
    [self.pendingRequests removeObjectForKey:requestKey];
    pending.completion(response, nil);
}

- (BOOL)ioFrameChannel:(Lookin_PTChannel *)channel shouldAcceptFrameOfType:(uint32_t)type tag:(uint32_t)tag payloadSize:(uint32_t)payloadSize {
    return YES;
}

- (void)ioFrameChannel:(Lookin_PTChannel *)channel didEndWithError:(NSError *)error {
    dispatch_block_t disconnectWaiter = self.disconnectWaiters[@(channel.uniqueID)];
    if (disconnectWaiter) {
        disconnectWaiter();
    }

    NSArray<NSString *> *targetIDs = [self.connectedChannels allKeysForObject:channel];
    for (NSString *targetID in targetIDs) {
        [self.connectedChannels removeObjectForKey:targetID];
    }

    NSArray<NSString *> *keys = [self.pendingRequests allKeys];
    for (NSString *key in keys) {
        LKXPendingRequest *pending = self.pendingRequests[key];
        if (pending.channel == channel) {
            [self.pendingRequests removeObjectForKey:key];
            pending.completion(nil, error ?: [self _bridgeErrorWithCode:@"session_not_connected" message:@"Channel ended."]);
        }
    }
}

#pragma mark - Projection

- (NSMutableDictionary *)_baseDictionaryForTarget:(LKXBridgeTarget *)target {
    NSMutableDictionary *payload = [@{
        @"target_id": target.targetID ?: @"",
        @"transport": target.transport ?: @"",
        @"port": @(target.port),
        @"device_id": target.deviceID ?: [NSNull null]
    } mutableCopy];
    if (target.deviceIdentifier.length > 0) {
        payload[@"device_identifier"] = target.deviceIdentifier;
    }
    if (target.deviceUDID.length > 0) {
        payload[@"udid"] = target.deviceUDID;
    }
    if (target.hostAddress.length > 0) {
        payload[@"host_address"] = target.hostAddress;
    }
    if (target.hostname.length > 0) {
        payload[@"hostname"] = target.hostname;
    }
    return payload;
}

- (NSDictionary *)_dictionaryForHierarchyInfo:(LookinHierarchyInfo *)info
                                       target:(LKXBridgeTarget *)target
                                      options:(NSDictionary * _Nullable)options {
    NSMutableArray<NSDictionary *> *allRoots = [NSMutableArray array];
    [info.displayItems enumerateObjectsUsingBlock:^(LookinDisplayItem * _Nonnull item, NSUInteger idx, BOOL * _Nonnull stop) {
        [allRoots addObject:[self _dictionaryForDisplayItem:item path:@[@(idx)] parentNodeID:nil]];
    }];

    NSMutableArray<NSDictionary *> *allFlatNodes = [NSMutableArray array];
    for (NSDictionary *root in allRoots) {
        [self _collectFlatNodesFromProjectedNode:root into:allFlatNodes];
    }

    NSDictionary *normalizedOptions = [self _normalizedHierarchyOptions:options];
    NSArray<NSDictionary *> *filteredRoots = [self _filteredRoots:allRoots options:normalizedOptions];
    NSMutableArray<NSDictionary *> *filteredFlatNodes = [NSMutableArray array];
    for (NSDictionary *root in filteredRoots) {
        [self _collectFlatNodesFromProjectedNode:root into:filteredFlatNodes];
    }
    self.cachedFlatNodesByTargetID[target.targetID] = filteredFlatNodes.copy;

    NSMutableDictionary *payload = [self _baseDictionaryForTarget:target];
    payload[@"server_version"] = @(info.serverVersion);
    payload[@"app"] = info.appInfo ? [self _dictionaryForAppInfo:info.appInfo] : @{};
    payload[@"root_count"] = @(filteredRoots.count);
    payload[@"roots"] = filteredRoots;
    payload[@"flat_node_count"] = @(filteredFlatNodes.count);
    payload[@"source_root_count"] = @(allRoots.count);
    payload[@"source_flat_node_count"] = @(allFlatNodes.count);
    payload[@"options"] = normalizedOptions ?: @{};
    return payload;
}

- (NSDictionary *)_dictionaryForDetail:(LookinDisplayItemDetail *)detail
                                target:(LKXBridgeTarget *)target
                        screenshotMode:(NSString *)screenshotMode {
    NSDictionary *screenshot = nil;
    if ([screenshotMode isEqualToString:LKXScreenshotModeSolo]) {
        screenshot = [self _persistImage:detail.soloScreenshot prefix:@"solo"];
    } else if ([screenshotMode isEqualToString:LKXScreenshotModeGroup]) {
        screenshot = [self _persistImage:detail.groupScreenshot prefix:@"group"];
    }

    NSMutableArray *subitems = [NSMutableArray array];
    [detail.subitems enumerateObjectsUsingBlock:^(LookinDisplayItem * _Nonnull item, NSUInteger idx, BOOL * _Nonnull stop) {
        [subitems addObject:[self _dictionaryForDisplayItem:item path:@[@(idx)] parentNodeID:@(detail.displayItemOid)]];
    }];

    NSMutableDictionary *payload = [self _baseDictionaryForTarget:target];
    payload[@"node_id"] = @(detail.displayItemOid);
    payload[@"frame"] = detail.frameValue ? [self _dictionaryForRect:[detail.frameValue rectValue]] : [NSNull null];
    payload[@"bounds"] = detail.boundsValue ? [self _dictionaryForRect:[detail.boundsValue rectValue]] : [NSNull null];
    payload[@"hidden"] = detail.hiddenValue ?: [NSNull null];
    payload[@"alpha"] = detail.alphaValue ?: [NSNull null];
    payload[@"custom_title"] = detail.customDisplayTitle ?: @"";
    payload[@"danceui_source"] = detail.danceUISource ?: @"";
    payload[@"attributes"] = [self _dictionaryForAttributeGroups:detail.attributesGroupList ?: @[]];
    payload[@"custom_attributes"] = [self _dictionaryForAttributeGroups:detail.customAttrGroupList ?: @[]];
    payload[@"subitems"] = subitems;
    payload[@"screenshot"] = screenshot ?: [NSNull null];
    return payload;
}

- (NSDictionary *)_dictionaryForAppInfo:(LookinAppInfo *)info {
    return @{
        @"app_name": info.appName ?: @"",
        @"bundle_id": info.appBundleIdentifier ?: @"",
        @"device_description": info.deviceDescription ?: @"",
        @"os_description": info.osDescription ?: @"",
        @"screen_width": @(info.screenWidth),
        @"screen_height": @(info.screenHeight),
        @"screen_scale": @(info.screenScale),
        @"server_version": @(info.serverVersion),
        @"server_readable_version": info.serverReadableVersion ?: @"",
        @"device_type": [self _deviceTypeName:info.deviceType]
    };
}

- (NSDictionary *)_dictionaryForDisplayItem:(LookinDisplayItem *)item
                                       path:(NSArray<NSNumber *> *)path
                               parentNodeID:(NSNumber * _Nullable)parentNodeID {
    NSMutableArray<NSDictionary *> *children = [NSMutableArray array];
    LookinObject *displayingObject = [item displayingObject];
    NSNumber *displayNodeID = displayingObject ? @(displayingObject.oid) : @0;
    id viewNodeID = item.viewObject ? @(item.viewObject.oid) : [NSNull null];
    id layerNodeID = item.layerObject ? @(item.layerObject.oid) : [NSNull null];
    NSNumber *detailNodeID = item.layerObject ? @(item.layerObject.oid) : displayNodeID;
    [item.subitems enumerateObjectsUsingBlock:^(LookinDisplayItem * _Nonnull child, NSUInteger idx, BOOL * _Nonnull stop) {
        NSMutableArray<NSNumber *> *childPath = [path mutableCopy];
        [childPath addObject:@(idx)];
        [children addObject:[self _dictionaryForDisplayItem:child path:childPath parentNodeID:detailNodeID]];
    }];

    NSArray<NSString *> *searchIdentifiers = [self _searchIdentifiersForDisplayItem:item];
    NSString *text = [self _primaryTextForDisplayItem:item];
    NSString *identifier = searchIdentifiers.firstObject ?: @"";

    return @{
        @"node_id": displayNodeID,
        @"detail_node_id": detailNodeID ?: [NSNull null],
        @"class_name": displayingObject ? [displayingObject rawClassName] ?: @"" : @"",
        @"memory_address": displayingObject.memoryAddress ?: @"",
        @"hidden": @(item.isHidden),
        @"alpha": @(item.alpha),
        @"frame": [self _dictionaryForRect:item.frame],
        @"bounds": [self _dictionaryForRect:item.bounds],
        @"has_children": @((item.subitems.count > 0)),
        @"child_count": @(item.subitems.count),
        @"represented_as_key_window": @(item.representedAsKeyWindow),
        @"custom_title": item.customDisplayTitle ?: @"",
        @"text": text ?: @"",
        @"identifier": identifier ?: @"",
        @"search_identifiers": searchIdentifiers ?: @[],
        @"view_oid": viewNodeID,
        @"layer_oid": layerNodeID,
        @"parent_node_id": parentNodeID ?: [NSNull null],
        @"path": path ?: @[],
        @"children": children
    };
}

- (void)_collectFlatNodesFromProjectedNode:(NSDictionary *)node into:(NSMutableArray<NSDictionary *> *)buffer {
    if (!node || !buffer) {
        return;
    }
    NSMutableDictionary *summary = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"node_id", @"detail_node_id", @"class_name", @"memory_address", @"hidden", @"alpha", @"frame", @"bounds", @"custom_title", @"text", @"identifier", @"search_identifiers", @"view_oid", @"layer_oid", @"parent_node_id", @"path", @"represented_as_key_window"]) {
        id value = node[key];
        if (value) {
            summary[key] = value;
        }
    }
    [buffer addObject:summary];
    for (NSDictionary *child in node[@"children"] ?: @[]) {
        [self _collectFlatNodesFromProjectedNode:child into:buffer];
    }
}

- (NSArray<NSDictionary *> *)_findMatchesInHierarchyInfo:(LookinHierarchyInfo *)info query:(NSDictionary *)query {
    NSMutableArray<NSDictionary *> *matches = [NSMutableArray array];
    NSString *classContains = [query[@"class_name_contains"] isKindOfClass:[NSString class]] ? [query[@"class_name_contains"] lowercaseString] : nil;
    NSString *customTitleContains = [query[@"custom_title_contains"] isKindOfClass:[NSString class]] ? [query[@"custom_title_contains"] lowercaseString] : nil;
    NSString *memoryAddressContains = [query[@"memory_address_contains"] isKindOfClass:[NSString class]] ? [query[@"memory_address_contains"] lowercaseString] : nil;
    NSString *textContains = [query[@"text_contains"] isKindOfClass:[NSString class]] ? [query[@"text_contains"] lowercaseString] : nil;
    NSString *identifierContains = [query[@"identifier_contains"] isKindOfClass:[NSString class]] ? [query[@"identifier_contains"] lowercaseString] : nil;
    NSNumber *nodeID = [query[@"node_id"] isKindOfClass:[NSNumber class]] ? query[@"node_id"] : nil;
    NSNumber *limit = [query[@"limit"] isKindOfClass:[NSNumber class]] ? query[@"limit"] : nil;
    NSDictionary *frameQuery = [query[@"frame"] isKindOfClass:[NSDictionary class]] ? query[@"frame"] : nil;
    NSString *frameMatch = [query[@"frame_match"] isKindOfClass:[NSString class]] ? [query[@"frame_match"] lowercaseString] : LKXHierarchyFrameMatchIntersects;
    NSNumber *hidden = [query[@"hidden"] isKindOfClass:[NSNumber class]] ? query[@"hidden"] : nil;

    __block BOOL stopSearching = NO;
    [info.displayItems enumerateObjectsUsingBlock:^(LookinDisplayItem * _Nonnull item, NSUInteger idx, BOOL * _Nonnull stop) {
        [self _searchDisplayItem:item
                            path:@[@(idx)]
                   parentNodeID:nil
                  classContains:classContains
            customTitleContains:customTitleContains
         memoryAddressContains:memoryAddressContains
                   textContains:textContains
             identifierContains:identifierContains
                          nodeID:nodeID
                           hidden:hidden
                       frameQuery:frameQuery
                       frameMatch:frameMatch
                           limit:limit.unsignedIntegerValue
                         matches:matches
                     stopSearching:&stopSearching];
        if (stopSearching) {
            *stop = YES;
        }
    }];
    return matches;
}

- (void)_searchDisplayItem:(LookinDisplayItem *)item
                      path:(NSArray<NSNumber *> *)path
              parentNodeID:(NSNumber * _Nullable)parentNodeID
             classContains:(NSString * _Nullable)classContains
       customTitleContains:(NSString * _Nullable)customTitleContains
     memoryAddressContains:(NSString * _Nullable)memoryAddressContains
              textContains:(NSString * _Nullable)textContains
        identifierContains:(NSString * _Nullable)identifierContains
                    nodeID:(NSNumber * _Nullable)nodeID
                    hidden:(NSNumber * _Nullable)hidden
                frameQuery:(NSDictionary * _Nullable)frameQuery
                frameMatch:(NSString * _Nullable)frameMatch
                     limit:(NSUInteger)limit
                   matches:(NSMutableArray<NSDictionary *> *)matches
             stopSearching:(BOOL *)stopSearching {
    if (*stopSearching) {
        return;
    }

    NSDictionary *projected = [self _dictionaryForDisplayItem:item path:path parentNodeID:parentNodeID];
    NSString *projectedClass = [projected[@"class_name"] lowercaseString];
    NSString *projectedTitle = [projected[@"custom_title"] lowercaseString];
    NSString *projectedAddress = [projected[@"memory_address"] lowercaseString];
    NSString *projectedText = [projected[@"text"] lowercaseString];
    NSArray<NSString *> *projectedIdentifiers = [projected[@"search_identifiers"] isKindOfClass:[NSArray class]] ? projected[@"search_identifiers"] : @[];
    NSNumber *projectedNodeID = projected[@"node_id"];

    BOOL matched = YES;
    if (classContains.length > 0 && [projectedClass rangeOfString:classContains].location == NSNotFound) {
        matched = NO;
    }
    if (matched && customTitleContains.length > 0 && [projectedTitle rangeOfString:customTitleContains].location == NSNotFound) {
        matched = NO;
    }
    if (matched && memoryAddressContains.length > 0 && [projectedAddress rangeOfString:memoryAddressContains].location == NSNotFound) {
        matched = NO;
    }
    if (matched && textContains.length > 0 && [projectedText rangeOfString:textContains].location == NSNotFound) {
        matched = NO;
    }
    if (matched && identifierContains.length > 0) {
        BOOL foundIdentifier = NO;
        for (NSString *identifier in projectedIdentifiers) {
            if ([[identifier lowercaseString] rangeOfString:identifierContains].location != NSNotFound) {
                foundIdentifier = YES;
                break;
            }
        }
        if (!foundIdentifier && [projectedTitle rangeOfString:identifierContains].location == NSNotFound) {
            matched = NO;
        }
    }
    if (matched && nodeID && ![projectedNodeID isEqual:nodeID]) {
        matched = NO;
    }
    if (matched && hidden && ![projected[@"hidden"] isEqual:hidden]) {
        matched = NO;
    }
    if (matched && frameQuery && ![self _projectedNode:projected matchesFrameQuery:frameQuery matchMode:frameMatch]) {
        matched = NO;
    }

    if (matched) {
        NSMutableDictionary *summary = [projected mutableCopy];
        [summary removeObjectForKey:@"children"];
        [summary setObject:@(item.subitems.count) forKey:@"child_count"];
        [matches addObject:summary];
        if (limit > 0 && matches.count >= limit) {
            *stopSearching = YES;
            return;
        }
    }

    [item.subitems enumerateObjectsUsingBlock:^(LookinDisplayItem * _Nonnull child, NSUInteger idx, BOOL * _Nonnull stop) {
        NSMutableArray<NSNumber *> *childPath = [path mutableCopy];
        [childPath addObject:@(idx)];
        [self _searchDisplayItem:child
                            path:childPath
                    parentNodeID:projectedNodeID
                   classContains:classContains
             customTitleContains:customTitleContains
          memoryAddressContains:memoryAddressContains
                   textContains:textContains
             identifierContains:identifierContains
                          nodeID:nodeID
                          hidden:hidden
                      frameQuery:frameQuery
                      frameMatch:frameMatch
                           limit:limit
                         matches:matches
                   stopSearching:stopSearching];
        if (*stopSearching) {
            *stop = YES;
        }
    }];
}

- (BOOL)_queryNeedsDetailEnrichment:(NSDictionary *)query {
    NSString *textContains = [query[@"text_contains"] isKindOfClass:[NSString class]] ? query[@"text_contains"] : nil;
    NSString *identifierContains = [query[@"identifier_contains"] isKindOfClass:[NSString class]] ? query[@"identifier_contains"] : nil;
    return textContains.length > 0 || identifierContains.length > 0;
}

- (void)_fetchSearchMetadataForHierarchyInfo:(LookinHierarchyInfo *)info
                                     channel:(Lookin_PTChannel *)channel
                                  completion:(void (^)(NSDictionary<NSNumber *, NSDictionary *> * _Nullable metadataByDetailNodeID, NSError * _Nullable error))completion {
    NSArray<LookinDisplayItem *> *flatItems = [LookinDisplayItem flatItemsFromHierarchicalItems:info.displayItems ?: @[]];
    if (flatItems.count == 0) {
        completion(@{}, nil);
        return;
    }

    NSMutableArray<LookinStaticAsyncUpdateTask *> *tasks = [NSMutableArray array];
    for (LookinDisplayItem *item in flatItems) {
        unsigned long detailOID = item.layerObject ? item.layerObject.oid : item.displayingObject.oid;
        if (detailOID == 0) {
            continue;
        }
        LookinStaticAsyncUpdateTask *task = [LookinStaticAsyncUpdateTask new];
        task.oid = detailOID;
        task.clientReadableVersion = LKXClientVersion;
        task.attrRequest = LookinDetailUpdateTaskAttrRequest_Need;
        task.needBasisVisualInfo = NO;
        task.needSubitems = NO;
        task.taskType = LookinStaticAsyncUpdateTaskTypeNoScreenshot;
        [tasks addObject:task];
    }

    if (tasks.count == 0) {
        completion(@{}, nil);
        return;
    }

    LookinStaticAsyncUpdateTasksPackage *package = [LookinStaticAsyncUpdateTasksPackage new];
    package.tasks = tasks;
    [self _sendRequestType:LookinRequestTypeHierarchyDetails data:@[package] channel:channel timeout:20 completion:^(LookinConnectionResponseAttachment * _Nullable response, NSError * _Nullable requestError) {
        if (requestError) {
            completion(nil, requestError);
            return;
        }
        if (response.error) {
            completion(nil, response.error);
            return;
        }
        if (![response.data isKindOfClass:[NSArray class]]) {
            completion(nil, [self _bridgeErrorWithCode:@"payload_decode_failed" message:@"Unexpected detail payload while enriching hierarchy search metadata."]);
            return;
        }

        NSMutableDictionary<NSNumber *, NSDictionary *> *metadataByDetailNodeID = [NSMutableDictionary dictionary];
        for (LookinDisplayItemDetail *detail in (NSArray *)response.data) {
            if (![detail isKindOfClass:[LookinDisplayItemDetail class]] || detail.failureCode == -1) {
                continue;
            }
            metadataByDetailNodeID[@(detail.displayItemOid)] = [self _searchMetadataForDetail:detail];
        }
        completion(metadataByDetailNodeID, nil);
    }];
}

- (NSDictionary *)_searchMetadataForDetail:(LookinDisplayItemDetail *)detail {
    NSMutableOrderedSet<NSString *> *identifiers = [NSMutableOrderedSet orderedSet];
    if (detail.customDisplayTitle.length > 0) {
        [identifiers addObject:detail.customDisplayTitle];
    }

    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    for (LookinAttributesGroup *group in detail.attributesGroupList ?: @[]) {
        if (group.identifier.length > 0) {
            [identifiers addObject:group.identifier];
        }
        if (group.userCustomTitle.length > 0) {
            [identifiers addObject:group.userCustomTitle];
        }
        for (LookinAttributesSection *section in group.attrSections ?: @[]) {
            if (section.identifier.length > 0) {
                [identifiers addObject:section.identifier];
            }
            for (LookinAttribute *attribute in section.attributes ?: @[]) {
                if (attribute.identifier.length > 0) {
                    [identifiers addObject:attribute.identifier];
                }
                if (attribute.displayTitle.length > 0) {
                    [identifiers addObject:attribute.displayTitle];
                }

                BOOL isTextAttribute = [@[LookinAttr_UILabel_Text_Text,
                                          LookinAttr_UITextField_Text_Text,
                                          LookinAttr_UITextField_Placeholder_Placeholder,
                                          LookinAttr_UITextView_Text_Text] containsObject:attribute.identifier];
                if (!isTextAttribute) {
                    NSString *displayTitle = attribute.displayTitle.lowercaseString ?: @"";
                    isTextAttribute = [displayTitle containsString:@"text"] || [displayTitle containsString:@"title"];
                }
                if (!isTextAttribute) {
                    continue;
                }

                id rawValue = [self _jsonValueFromObject:attribute.value];
                NSString *textValue = [rawValue isKindOfClass:[NSString class]] ? rawValue : nil;
                if (textValue.length > 0) {
                    [texts addObject:textValue];
                }
            }
        }
    }

    return @{
        @"text": texts.firstObject ?: @"",
        @"identifier": identifiers.firstObject ?: @"",
        @"search_identifiers": identifiers.array ?: @[]
    };
}

- (NSArray<NSDictionary *> *)_rootsByApplyingSearchMetadata:(NSDictionary<NSNumber *, NSDictionary *> *)metadataByDetailNodeID
                                                    toRoots:(NSArray<NSDictionary *> *)roots {
    NSMutableArray<NSDictionary *> *updatedRoots = [NSMutableArray array];
    for (NSDictionary *root in roots) {
        [updatedRoots addObject:[self _projectedNode:root byApplyingSearchMetadata:metadataByDetailNodeID]];
    }
    return updatedRoots;
}

- (NSDictionary *)_projectedNode:(NSDictionary *)node
         byApplyingSearchMetadata:(NSDictionary<NSNumber *, NSDictionary *> *)metadataByDetailNodeID {
    NSMutableDictionary *copy = [node mutableCopy];
    NSNumber *detailNodeID = [node[@"detail_node_id"] isKindOfClass:[NSNumber class]] ? node[@"detail_node_id"] : nil;
    NSDictionary *metadata = detailNodeID ? metadataByDetailNodeID[detailNodeID] : nil;
    if (metadata) {
        copy[@"text"] = metadata[@"text"] ?: @"";
        copy[@"identifier"] = metadata[@"identifier"] ?: @"";
        copy[@"search_identifiers"] = metadata[@"search_identifiers"] ?: @[];
    }

    NSMutableArray<NSDictionary *> *children = [NSMutableArray array];
    for (NSDictionary *child in [node[@"children"] isKindOfClass:[NSArray class]] ? node[@"children"] : @[]) {
        [children addObject:[self _projectedNode:child byApplyingSearchMetadata:metadataByDetailNodeID]];
    }
    copy[@"children"] = children;
    return copy;
}

- (NSArray<NSDictionary *> *)_findMatchesInProjectedRoots:(NSArray<NSDictionary *> *)roots query:(NSDictionary *)query {
    NSMutableArray<NSDictionary *> *matches = [NSMutableArray array];
    NSUInteger limit = [query[@"limit"] respondsToSelector:@selector(unsignedIntegerValue)] ? [query[@"limit"] unsignedIntegerValue] : 0;
    BOOL stopSearching = NO;
    for (NSDictionary *root in roots) {
        [self _searchProjectedNode:root query:query matches:matches limit:limit stopSearching:&stopSearching];
        if (stopSearching) {
            break;
        }
    }
    return matches;
}

- (void)_searchProjectedNode:(NSDictionary *)node
                       query:(NSDictionary *)query
                     matches:(NSMutableArray<NSDictionary *> *)matches
                       limit:(NSUInteger)limit
               stopSearching:(BOOL *)stopSearching {
    if (*stopSearching) {
        return;
    }

    NSString *classContains = [query[@"class_name_contains"] isKindOfClass:[NSString class]] ? [query[@"class_name_contains"] lowercaseString] : nil;
    NSString *customTitleContains = [query[@"custom_title_contains"] isKindOfClass:[NSString class]] ? [query[@"custom_title_contains"] lowercaseString] : nil;
    NSString *memoryAddressContains = [query[@"memory_address_contains"] isKindOfClass:[NSString class]] ? [query[@"memory_address_contains"] lowercaseString] : nil;
    NSString *textContains = [query[@"text_contains"] isKindOfClass:[NSString class]] ? [query[@"text_contains"] lowercaseString] : nil;
    NSString *identifierContains = [query[@"identifier_contains"] isKindOfClass:[NSString class]] ? [query[@"identifier_contains"] lowercaseString] : nil;
    NSNumber *nodeID = [query[@"node_id"] isKindOfClass:[NSNumber class]] ? query[@"node_id"] : nil;
    NSNumber *hidden = [query[@"hidden"] isKindOfClass:[NSNumber class]] ? query[@"hidden"] : nil;
    NSDictionary *frameQuery = [query[@"frame"] isKindOfClass:[NSDictionary class]] ? query[@"frame"] : nil;
    NSString *frameMatch = [query[@"frame_match"] isKindOfClass:[NSString class]] ? [query[@"frame_match"] lowercaseString] : LKXHierarchyFrameMatchIntersects;

    NSString *projectedClass = [node[@"class_name"] lowercaseString];
    NSString *projectedTitle = [node[@"custom_title"] lowercaseString];
    NSString *projectedAddress = [node[@"memory_address"] lowercaseString];
    NSString *projectedText = [node[@"text"] lowercaseString];
    NSArray<NSString *> *projectedIdentifiers = [node[@"search_identifiers"] isKindOfClass:[NSArray class]] ? node[@"search_identifiers"] : @[];

    BOOL matched = YES;
    if (classContains.length > 0 && [projectedClass rangeOfString:classContains].location == NSNotFound) {
        matched = NO;
    }
    if (matched && customTitleContains.length > 0 && [projectedTitle rangeOfString:customTitleContains].location == NSNotFound) {
        matched = NO;
    }
    if (matched && memoryAddressContains.length > 0 && [projectedAddress rangeOfString:memoryAddressContains].location == NSNotFound) {
        matched = NO;
    }
    if (matched && textContains.length > 0 && [projectedText rangeOfString:textContains].location == NSNotFound) {
        matched = NO;
    }
    if (matched && identifierContains.length > 0) {
        BOOL foundIdentifier = NO;
        for (NSString *identifier in projectedIdentifiers) {
            if ([[identifier lowercaseString] rangeOfString:identifierContains].location != NSNotFound) {
                foundIdentifier = YES;
                break;
            }
        }
        if (!foundIdentifier && [projectedTitle rangeOfString:identifierContains].location == NSNotFound) {
            matched = NO;
        }
    }
    if (matched && nodeID && ![node[@"node_id"] isEqual:nodeID]) {
        matched = NO;
    }
    if (matched && hidden && ![node[@"hidden"] isEqual:hidden]) {
        matched = NO;
    }
    if (matched && frameQuery && ![self _projectedNode:node matchesFrameQuery:frameQuery matchMode:frameMatch]) {
        matched = NO;
    }

    if (matched) {
        NSMutableDictionary *summary = [node mutableCopy];
        [summary removeObjectForKey:@"children"];
        [matches addObject:summary];
        if (limit > 0 && matches.count >= limit) {
            *stopSearching = YES;
            return;
        }
    }

    for (NSDictionary *child in [node[@"children"] isKindOfClass:[NSArray class]] ? node[@"children"] : @[]) {
        [self _searchProjectedNode:child query:query matches:matches limit:limit stopSearching:stopSearching];
        if (*stopSearching) {
            return;
        }
    }
}

- (NSArray<NSDictionary *> *)_filteredRoots:(NSArray<NSDictionary *> *)roots options:(NSDictionary * _Nullable)options {
    if (!roots.count) {
        return @[];
    }

    BOOL includeHidden = options[@"include_hidden"] ? [options[@"include_hidden"] boolValue] : YES;
    NSNumber *depth = [options[@"depth"] isKindOfClass:[NSNumber class]] ? options[@"depth"] : nil;
    NSArray<NSNumber *> *focusPath = [options[@"focus_path"] isKindOfClass:[NSArray class]] ? options[@"focus_path"] : nil;

    NSMutableArray<NSDictionary *> *workingRoots = [NSMutableArray array];
    for (NSDictionary *root in roots) {
        NSDictionary *filteredRoot = includeHidden ? root : [self _copyProjectedNode:root excludingHidden:YES];
        if (filteredRoot) {
            [workingRoots addObject:filteredRoot];
        }
    }

    if (focusPath.count > 0) {
        NSDictionary *focusedNode = [self _projectedNodeAtPath:focusPath withinRoots:workingRoots];
        if (focusedNode) {
            workingRoots = [NSMutableArray arrayWithObject:focusedNode];
        } else {
            [workingRoots removeAllObjects];
        }
    }

    if (depth) {
        NSMutableArray<NSDictionary *> *depthLimitedRoots = [NSMutableArray array];
        for (NSDictionary *root in workingRoots) {
            NSDictionary *limited = [self _copyProjectedNode:root limitingDepth:depth.integerValue currentDepth:0];
            if (limited) {
                [depthLimitedRoots addObject:limited];
            }
        }
        workingRoots = depthLimitedRoots;
    }

    return workingRoots.copy;
}

- (NSDictionary * _Nullable)_copyProjectedNode:(NSDictionary *)node excludingHidden:(BOOL)excludingHidden {
    if (!node) {
        return nil;
    }
    if (excludingHidden && [node[@"hidden"] respondsToSelector:@selector(boolValue)] && [node[@"hidden"] boolValue]) {
        return nil;
    }

    NSMutableDictionary *copy = [node mutableCopy];
    NSMutableArray<NSDictionary *> *children = [NSMutableArray array];
    for (NSDictionary *child in [node[@"children"] isKindOfClass:[NSArray class]] ? node[@"children"] : @[]) {
        NSDictionary *filteredChild = [self _copyProjectedNode:child excludingHidden:excludingHidden];
        if (filteredChild) {
            [children addObject:filteredChild];
        }
    }
    copy[@"children"] = children;
    copy[@"child_count"] = @(children.count);
    copy[@"has_children"] = @(children.count > 0);
    return copy;
}

- (NSDictionary * _Nullable)_copyProjectedNode:(NSDictionary *)node
                                  limitingDepth:(NSInteger)maxDepth
                                   currentDepth:(NSInteger)currentDepth {
    if (!node) {
        return nil;
    }

    NSMutableDictionary *copy = [node mutableCopy];
    if (currentDepth >= maxDepth) {
        copy[@"children"] = @[];
        copy[@"child_count"] = @0;
        copy[@"has_children"] = @0;
        return copy;
    }

    NSMutableArray<NSDictionary *> *children = [NSMutableArray array];
    for (NSDictionary *child in [node[@"children"] isKindOfClass:[NSArray class]] ? node[@"children"] : @[]) {
        NSDictionary *limitedChild = [self _copyProjectedNode:child limitingDepth:maxDepth currentDepth:(currentDepth + 1)];
        if (limitedChild) {
            [children addObject:limitedChild];
        }
    }
    copy[@"children"] = children;
    copy[@"child_count"] = @(children.count);
    copy[@"has_children"] = @(children.count > 0);
    return copy;
}

- (NSDictionary * _Nullable)_projectedNodeAtPath:(NSArray<NSNumber *> *)path withinRoots:(NSArray<NSDictionary *> *)roots {
    if (path.count == 0 || roots.count == 0) {
        return nil;
    }

    NSInteger rootIndex = path.firstObject.integerValue;
    if (rootIndex < 0 || rootIndex >= (NSInteger)roots.count) {
        return nil;
    }

    NSDictionary *current = roots[rootIndex];
    for (NSUInteger idx = 1; idx < path.count; idx++) {
        NSArray<NSDictionary *> *children = [current[@"children"] isKindOfClass:[NSArray class]] ? current[@"children"] : nil;
        NSInteger childIndex = path[idx].integerValue;
        if (childIndex < 0 || childIndex >= (NSInteger)children.count) {
            return nil;
        }
        current = children[childIndex];
    }
    return current;
}

- (NSArray<NSString *> *)_searchIdentifiersForDisplayItem:(LookinDisplayItem *)item {
    NSMutableOrderedSet<NSString *> *identifiers = [NSMutableOrderedSet orderedSet];
    if (item.customDisplayTitle.length > 0) {
        [identifiers addObject:item.customDisplayTitle];
    }

    for (LookinAttributesGroup *group in [item queryAllAttrGroupList] ?: @[]) {
        if (group.identifier.length > 0) {
            [identifiers addObject:group.identifier];
        }
        if (group.userCustomTitle.length > 0) {
            [identifiers addObject:group.userCustomTitle];
        }
        for (LookinAttributesSection *section in group.attrSections ?: @[]) {
            if (section.identifier.length > 0) {
                [identifiers addObject:section.identifier];
            }
            for (LookinAttribute *attribute in section.attributes ?: @[]) {
                if (attribute.identifier.length > 0) {
                    [identifiers addObject:attribute.identifier];
                }
                if (attribute.displayTitle.length > 0) {
                    [identifiers addObject:attribute.displayTitle];
                }
            }
        }
    }
    return identifiers.array ?: @[];
}

- (NSString *)_primaryTextForDisplayItem:(LookinDisplayItem *)item {
    NSArray<NSString *> *candidateAttributeIDs = @[
        LookinAttr_UILabel_Text_Text,
        LookinAttr_UITextField_Text_Text,
        LookinAttr_UITextField_Placeholder_Placeholder,
        LookinAttr_UITextView_Text_Text
    ];

    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    for (LookinAttributesGroup *group in [item queryAllAttrGroupList] ?: @[]) {
        for (LookinAttributesSection *section in group.attrSections ?: @[]) {
            for (LookinAttribute *attribute in section.attributes ?: @[]) {
                BOOL shouldUseAttribute = NO;
                if ([candidateAttributeIDs containsObject:attribute.identifier]) {
                    shouldUseAttribute = YES;
                } else if ([attribute.displayTitle.lowercaseString containsString:@"text"] || [attribute.displayTitle.lowercaseString containsString:@"title"]) {
                    shouldUseAttribute = YES;
                }

                if (!shouldUseAttribute) {
                    continue;
                }
                NSString *textValue = [[self _jsonValueFromObject:attribute.value] isKindOfClass:[NSString class]] ? [self _jsonValueFromObject:attribute.value] : nil;
                if (textValue.length > 0) {
                    [texts addObject:textValue];
                }
            }
        }
    }
    return texts.firstObject ?: @"";
}

- (BOOL)_projectedNode:(NSDictionary *)node matchesFrameQuery:(NSDictionary *)frameQuery matchMode:(NSString *)frameMatch {
    NSDictionary *frameDict = [node[@"frame"] isKindOfClass:[NSDictionary class]] ? node[@"frame"] : nil;
    if (!frameDict) {
        return NO;
    }

    CGRect nodeFrame = CGRectMake([frameDict[@"x"] doubleValue],
                                  [frameDict[@"y"] doubleValue],
                                  [frameDict[@"width"] doubleValue],
                                  [frameDict[@"height"] doubleValue]);
    CGRect queryFrame = CGRectMake([frameQuery[@"x"] doubleValue],
                                   [frameQuery[@"y"] doubleValue],
                                   [frameQuery[@"width"] doubleValue],
                                   [frameQuery[@"height"] doubleValue]);

    if ([frameMatch isEqualToString:LKXHierarchyFrameMatchExact]) {
        return CGRectEqualToRect(nodeFrame, queryFrame);
    }
    if ([frameMatch isEqualToString:LKXHierarchyFrameMatchContains]) {
        return CGRectContainsRect(nodeFrame, queryFrame);
    }
    return CGRectIntersectsRect(nodeFrame, queryFrame);
}

- (NSArray<NSDictionary *> *)_dictionaryForAttributeGroups:(NSArray<LookinAttributesGroup *> *)groups {
    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
    for (LookinAttributesGroup *group in groups) {
        NSMutableArray<NSDictionary *> *sections = [NSMutableArray array];
        for (LookinAttributesSection *section in group.attrSections ?: @[]) {
            NSMutableArray<NSDictionary *> *attributes = [NSMutableArray array];
            for (LookinAttribute *attribute in section.attributes ?: @[]) {
                [attributes addObject:@{
                    @"identifier": attribute.identifier ?: @"",
                    @"display_title": attribute.displayTitle ?: @"",
                    @"attr_type": @(attribute.attrType),
                    @"value": [self _jsonValueFromObject:attribute.value] ?: [NSNull null],
                    @"extra_value": [self _jsonValueFromObject:attribute.extraValue] ?: [NSNull null],
                    @"custom_setter_id": attribute.customSetterID ?: @""
                }];
            }
            [sections addObject:@{
                @"identifier": section.identifier ?: @"",
                @"attributes": attributes
            }];
        }
        [result addObject:@{
            @"identifier": group.identifier ?: @"",
            @"title": group.userCustomTitle ?: @"",
            @"unique_key": [group uniqueKey] ?: @"",
            @"is_user_custom": @([group isUserCustom]),
            @"sections": sections
        }];
    }
    return result;
}

- (id)_jsonValueFromObject:(id)object {
    if (!object) {
        return nil;
    }
    if ([object isKindOfClass:[NSString class]] || [object isKindOfClass:[NSNumber class]]) {
        return object;
    }
    if ([object isKindOfClass:[NSArray class]]) {
        NSMutableArray *items = [NSMutableArray array];
        for (id value in (NSArray *)object) {
            [items addObject:[self _jsonValueFromObject:value] ?: [NSNull null]];
        }
        return items;
    }
    if ([object isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];
        [(NSDictionary *)object enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
            dictionary[[key description]] = [self _jsonValueFromObject:value] ?: [NSNull null];
        }];
        return dictionary;
    }
    if ([object isKindOfClass:[LookinObject class]]) {
        LookinObject *lookinObject = (LookinObject *)object;
        return @{
            @"oid": @(lookinObject.oid),
            @"memory_address": lookinObject.memoryAddress ?: @"",
            @"class_chain": lookinObject.classChainList ?: @[],
            @"class_name": [lookinObject rawClassName] ?: @"",
            @"special_trace": lookinObject.specialTrace ?: @""
        };
    }
    if ([object isKindOfClass:[LookinAutoLayoutConstraint class]]) {
        LookinAutoLayoutConstraint *constraint = (LookinAutoLayoutConstraint *)object;
        return @{
            @"effective": @(constraint.effective),
            @"active": @(constraint.active),
            @"should_be_archived": @(constraint.shouldBeArchived),
            @"first_item": [self _jsonValueFromObject:constraint.firstItem] ?: [NSNull null],
            @"first_item_type": @(constraint.firstItemType),
            @"first_attribute": @(constraint.firstAttribute),
            @"relation": @(constraint.relation),
            @"second_item": [self _jsonValueFromObject:constraint.secondItem] ?: [NSNull null],
            @"second_item_type": @(constraint.secondItemType),
            @"second_attribute": @(constraint.secondAttribute),
            @"multiplier": @(constraint.multiplier),
            @"constant": @(constraint.constant),
            @"priority": @(constraint.priority),
            @"identifier": constraint.identifier ?: @""
        };
    }
    if ([object isKindOfClass:[LookinStringTwoTuple class]]) {
        LookinStringTwoTuple *tuple = (LookinStringTwoTuple *)object;
        return @{@"first": tuple.first ?: @"", @"second": tuple.second ?: @""};
    }
    if ([object isKindOfClass:[LookinTwoTuple class]]) {
        LookinTwoTuple *tuple = (LookinTwoTuple *)object;
        return @{
            @"first": [self _jsonValueFromObject:tuple.first] ?: [NSNull null],
            @"second": [self _jsonValueFromObject:tuple.second] ?: [NSNull null]
        };
    }
    if ([object isKindOfClass:[NSValue class]]) {
        const char *type = [(NSValue *)object objCType];
        if (strcmp(type, @encode(CGRect)) == 0) {
            return [self _dictionaryForRect:[(NSValue *)object rectValue]];
        }
        if (strcmp(type, @encode(CGPoint)) == 0) {
            CGPoint point = [(NSValue *)object pointValue];
            return @{@"x": @(point.x), @"y": @(point.y)};
        }
        if (strcmp(type, @encode(CGSize)) == 0) {
            CGSize size = [(NSValue *)object sizeValue];
            return @{@"width": @(size.width), @"height": @(size.height)};
        }
        return [object description];
    }
    return [object description];
}

- (NSDictionary *)_persistImage:(NSImage *)image prefix:(NSString *)prefix {
    if (!image) {
        return nil;
    }
    NSData *tiffData = image.TIFFRepresentation;
    if (!tiffData.length) {
        return nil;
    }
    NSBitmapImageRep *bitmapRep = [NSBitmapImageRep imageRepWithData:tiffData];
    NSData *data = [bitmapRep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    if (!data.length) {
        return nil;
    }
    NSString *dirPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"lookinextension-screenshots"];
    NSError *dirError = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:dirPath withIntermediateDirectories:YES attributes:nil error:&dirError];
    if (dirError) {
        return nil;
    }
    NSString *fileName = [NSString stringWithFormat:@"%@-%@.png", prefix, NSUUID.UUID.UUIDString];
    NSString *filePath = [dirPath stringByAppendingPathComponent:fileName];
    if (![data writeToFile:filePath atomically:YES]) {
        return nil;
    }
    return @{
        @"path": filePath,
        @"format": @"png",
        @"bytes": @(data.length)
    };
}

- (LookinStaticAsyncUpdateTaskType)_taskTypeForScreenshotMode:(NSString *)mode {
    if ([mode isEqualToString:LKXScreenshotModeSolo]) {
        return LookinStaticAsyncUpdateTaskTypeSoloScreenshot;
    }
    if ([mode isEqualToString:LKXScreenshotModeGroup]) {
        return LookinStaticAsyncUpdateTaskTypeGroupScreenshot;
    }
    return LookinStaticAsyncUpdateTaskTypeNoScreenshot;
}

- (NSDictionary *)_dictionaryForRect:(CGRect)rect {
    return @{
        @"x": @(rect.origin.x),
        @"y": @(rect.origin.y),
        @"width": @(rect.size.width),
        @"height": @(rect.size.height)
    };
}

#pragma mark - Parsing

- (void)_loadStateStoreIntoMemory {
    NSDictionary *store = [self _readStateStore];
    NSDictionary *sessions = [store[@"sessions_by_id"] isKindOfClass:[NSDictionary class]] ? store[@"sessions_by_id"] : @{};
    NSDictionary *snapshots = [store[@"snapshots_by_id"] isKindOfClass:[NSDictionary class]] ? store[@"snapshots_by_id"] : @{};

    [self.sessionsByID removeAllObjects];
    [sessions enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDictionary *record, BOOL *stop) {
        if ([key isKindOfClass:[NSString class]] && [record isKindOfClass:[NSDictionary class]]) {
            self.sessionsByID[key] = [record mutableCopy];
        }
    }];

    [self.snapshotsByID removeAllObjects];
    [snapshots enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDictionary *record, BOOL *stop) {
        if ([key isKindOfClass:[NSString class]] && [record isKindOfClass:[NSDictionary class]]) {
            self.snapshotsByID[key] = [record mutableCopy];
        }
    }];
}

- (NSDictionary *)_readStateStore {
    NSData *data = [NSData dataWithContentsOfFile:[self _stateStorePath]];
    if (!data.length) {
        return @{};
    }

    NSError *jsonError = nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:&jsonError];
    if (jsonError || ![object isKindOfClass:[NSDictionary class]]) {
        return @{};
    }
    return object;
}

- (NSString *)_stateStorePath {
    NSString *dirPath = [NSTemporaryDirectory() stringByAppendingPathComponent:LKXStateStoreDirectoryName];
    [[NSFileManager defaultManager] createDirectoryAtPath:dirPath withIntermediateDirectories:YES attributes:nil error:nil];
    return [dirPath stringByAppendingPathComponent:LKXStateStoreFileName];
}

- (void)_persistStateStore {
    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    NSMutableDictionary *sessions = [NSMutableDictionary dictionary];
    [self.sessionsByID enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDictionary *record, BOOL *stop) {
        sessions[key] = record ?: @{};
    }];
    NSMutableDictionary *snapshots = [NSMutableDictionary dictionary];
    [self.snapshotsByID enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDictionary *record, BOOL *stop) {
        snapshots[key] = record ?: @{};
    }];
    payload[@"sessions_by_id"] = sessions;
    payload[@"snapshots_by_id"] = snapshots;

    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:NSJSONWritingPrettyPrinted error:nil];
    if (data.length > 0) {
        [data writeToFile:[self _stateStorePath] atomically:YES];
    }
}

- (NSString *)_timestampStringForNow {
    static NSDateFormatter *formatter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
        formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
    });
    return [formatter stringFromDate:[NSDate date]];
}

- (NSMutableDictionary * _Nullable)_sessionRecordForID:(NSString *)sessionID {
    if (sessionID.length == 0) {
        return nil;
    }
    id record = self.sessionsByID[sessionID];
    return [record isKindOfClass:[NSMutableDictionary class]] ? record : nil;
}

- (NSDictionary * _Nullable)_sanitizedSessionRecord:(NSDictionary * _Nullable)record {
    if (![record isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    return @{
        @"session_id": record[@"session_id"] ?: @"",
        @"target_id": record[@"target_id"] ?: @"",
        @"created_at": record[@"created_at"] ?: @"",
        @"updated_at": record[@"updated_at"] ?: @"",
        @"snapshot_ids": record[@"snapshot_ids"] ?: @[]
    };
}

- (NSDictionary * _Nullable)_sanitizedSnapshotRecord:(NSDictionary * _Nullable)record {
    if (![record isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    NSDictionary *hierarchy = [record[@"hierarchy"] isKindOfClass:[NSDictionary class]] ? record[@"hierarchy"] : @{};
    return @{
        @"snapshot_id": record[@"snapshot_id"] ?: @"",
        @"session_id": record[@"session_id"] ?: @"",
        @"target_id": record[@"target_id"] ?: @"",
        @"name": record[@"name"] ?: @"",
        @"created_at": record[@"created_at"] ?: @"",
        @"options": record[@"options"] ?: @{},
        @"root_count": hierarchy[@"root_count"] ?: @0,
        @"flat_node_count": hierarchy[@"flat_node_count"] ?: @0
    };
}

- (LKXBridgeTarget * _Nullable)_resolveTargetWithTargetID:(NSString * _Nullable)targetID
                                                sessionID:(NSString * _Nullable)sessionID
                                                    error:(NSError * _Nullable __autoreleasing *)error {
    if (sessionID.length > 0) {
        NSDictionary *session = self.sessionsByID[sessionID];
        NSString *storedTargetID = [session[@"target_id"] isKindOfClass:[NSString class]] ? session[@"target_id"] : nil;
        if (storedTargetID.length == 0) {
            if (error) {
                *error = [self _bridgeErrorWithCode:@"session_not_found" message:@"Unknown session identifier."];
            }
            return nil;
        }
        LKXBridgeTarget *target = [self _parseTargetID:storedTargetID];
        if (!target && error) {
            *error = [self _bridgeErrorWithCode:@"target_not_found" message:@"Stored session target is no longer valid."];
        }
        return target;
    }

    if (targetID.length == 0) {
        if (error) {
            *error = [self _bridgeErrorWithCode:@"invalid_arguments" message:@"Either target_id or session_id is required."];
        }
        return nil;
    }

    LKXBridgeTarget *target = [self _parseTargetID:targetID];
    if (!target && error) {
        *error = [self _bridgeErrorWithCode:@"target_not_found" message:@"Invalid target identifier."];
    }
    return target;
}

- (NSDictionary *)_normalizedHierarchyOptions:(NSDictionary * _Nullable)options {
    NSMutableDictionary *normalized = [NSMutableDictionary dictionary];
    BOOL includeHidden = YES;
    if ([options[@"include_hidden"] respondsToSelector:@selector(boolValue)]) {
        includeHidden = [options[@"include_hidden"] boolValue];
    }
    normalized[@"include_hidden"] = @(includeHidden);

    NSNumber *depth = [options[@"depth"] isKindOfClass:[NSNumber class]] ? options[@"depth"] : nil;
    if (depth && depth.integerValue >= 0) {
        normalized[@"depth"] = @((NSInteger)depth.integerValue);
    }

    NSArray *focusPath = [options[@"focus_path"] isKindOfClass:[NSArray class]] ? options[@"focus_path"] : nil;
    if (focusPath.count > 0) {
        NSMutableArray<NSNumber *> *sanitizedPath = [NSMutableArray array];
        for (id value in focusPath) {
            if ([value respondsToSelector:@selector(integerValue)]) {
                NSInteger index = [value integerValue];
                if (index < 0) {
                    continue;
                }
                [sanitizedPath addObject:@(index)];
            }
        }
        if (sanitizedPath.count > 0) {
            normalized[@"focus_path"] = sanitizedPath;
        }
    }
    return normalized;
}

- (NSDictionary *)_diffPayloadForSnapshot:(NSDictionary *)snapshotA
                          againstSnapshot:(NSDictionary *)snapshotB
                                  session:(NSDictionary *)session {
    NSDictionary *hierarchyA = [snapshotA[@"hierarchy"] isKindOfClass:[NSDictionary class]] ? snapshotA[@"hierarchy"] : @{};
    NSDictionary *hierarchyB = [snapshotB[@"hierarchy"] isKindOfClass:[NSDictionary class]] ? snapshotB[@"hierarchy"] : @{};
    NSArray *rootsA = [hierarchyA[@"roots"] isKindOfClass:[NSArray class]] ? hierarchyA[@"roots"] : @[];
    NSArray *rootsB = [hierarchyB[@"roots"] isKindOfClass:[NSArray class]] ? hierarchyB[@"roots"] : @[];

    NSMutableArray<NSDictionary *> *flatA = [NSMutableArray array];
    for (NSDictionary *root in rootsA) {
        [self _collectFlatNodesFromProjectedNode:root into:flatA];
    }
    NSMutableArray<NSDictionary *> *flatB = [NSMutableArray array];
    for (NSDictionary *root in rootsB) {
        [self _collectFlatNodesFromProjectedNode:root into:flatB];
    }

    NSMutableDictionary<NSString *, NSDictionary *> *nodesByPathA = [NSMutableDictionary dictionary];
    for (NSDictionary *node in flatA) {
        nodesByPathA[[self _pathKeyForNode:node]] = node;
    }
    NSMutableDictionary<NSString *, NSDictionary *> *nodesByPathB = [NSMutableDictionary dictionary];
    for (NSDictionary *node in flatB) {
        nodesByPathB[[self _pathKeyForNode:node]] = node;
    }

    NSMutableArray<NSDictionary *> *added = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *removed = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *changed = [NSMutableArray array];

    NSMutableOrderedSet<NSString *> *allKeys = [NSMutableOrderedSet orderedSetWithArray:nodesByPathA.allKeys];
    [allKeys addObjectsFromArray:nodesByPathB.allKeys];

    for (NSString *pathKey in allKeys) {
        NSDictionary *nodeA = nodesByPathA[pathKey];
        NSDictionary *nodeB = nodesByPathB[pathKey];
        if (nodeA && !nodeB) {
            [removed addObject:nodeA];
            continue;
        }
        if (!nodeA && nodeB) {
            [added addObject:nodeB];
            continue;
        }

        NSDictionary *fieldChanges = [self _fieldChangesFromNode:nodeA toNode:nodeB];
        if (fieldChanges.count > 0) {
            [changed addObject:@{
                @"path": nodeA[@"path"] ?: @[],
                @"node_before": nodeA,
                @"node_after": nodeB,
                @"changes": fieldChanges
            }];
        }
    }

    return @{
        @"session_id": session[@"session_id"] ?: @"",
        @"target_id": session[@"target_id"] ?: @"",
        @"snapshot_a": [self _sanitizedSnapshotRecord:snapshotA] ?: @{},
        @"snapshot_b": [self _sanitizedSnapshotRecord:snapshotB] ?: @{},
        @"summary": @{
            @"added_count": @(added.count),
            @"removed_count": @(removed.count),
            @"changed_count": @(changed.count),
            @"before_flat_node_count": @(flatA.count),
            @"after_flat_node_count": @(flatB.count)
        },
        @"added": added,
        @"removed": removed,
        @"changed": changed
    };
}

- (NSDictionary *)_fieldChangesFromNode:(NSDictionary *)nodeA toNode:(NSDictionary *)nodeB {
    NSMutableDictionary *changes = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"class_name", @"custom_title", @"text", @"identifier", @"hidden", @"alpha", @"frame", @"bounds", @"child_count"]) {
        id valueA = nodeA[key];
        id valueB = nodeB[key];
        BOOL equal = (valueA == valueB) || [valueA isEqual:valueB];
        if (!equal) {
            changes[key] = @{
                @"before": valueA ?: [NSNull null],
                @"after": valueB ?: [NSNull null]
            };
        }
    }
    return changes;
}

- (NSString *)_pathKeyForNode:(NSDictionary *)node {
    NSArray *path = [node[@"path"] isKindOfClass:[NSArray class]] ? node[@"path"] : @[];
    NSMutableArray<NSString *> *components = [NSMutableArray array];
    for (NSNumber *index in path) {
        [components addObject:index.stringValue];
    }
    return [components componentsJoinedByString:@"/"];
}

- (LKXBridgeTarget * _Nullable)_parseTargetID:(NSString *)targetID {
    NSArray<NSString *> *parts = [targetID componentsSeparatedByString:@":"];
    if (parts.count < 2) {
        return nil;
    }

    NSString *transport = parts.firstObject;
    LKXBridgeTarget *target = [LKXBridgeTarget new];
    target.transport = transport;

    if ([transport isEqualToString:LKXTransportSimulator] && parts.count == 2) {
        target.port = parts[1].intValue;
        target.targetID = targetID;
        return target.port > 0 ? target : nil;
    }

    if ([transport isEqualToString:LKXTransportUSB] && parts.count == 3) {
        target.deviceID = @([parts[1] integerValue]);
        target.port = parts[2].intValue;
        target.targetID = targetID;
        return (target.deviceID && target.port > 0) ? target : nil;
    }

    if ([transport isEqualToString:LKXTransportCoreDevice] && parts.count == 3) {
        target.deviceIdentifier = parts[1];
        target.port = parts[2].intValue;
        if (target.deviceIdentifier.length == 0 || target.port <= 0) {
            return nil;
        }
        NSError *error = nil;
        [self.coreDeviceRecordsByIdentifier removeAllObjects];
        NSDictionary *recordsByIdentifier = [self _loadCoreDeviceRecordsByIdentifier:&error];
        NSDictionary *record = recordsByIdentifier[target.deviceIdentifier];
        LKXBridgeTarget *resolvedTarget = record ? [self _coreDeviceTargetFromRecord:record port:target.port] : nil;
        if (!resolvedTarget) {
            return nil;
        }
        resolvedTarget.targetID = targetID;
        return resolvedTarget;
    }

    return nil;
}

- (NSString *)_targetIDForTransport:(NSString *)transport
                               port:(int)port
                           deviceID:(NSNumber * _Nullable)deviceID
                    deviceIdentifier:(NSString * _Nullable)deviceIdentifier {
    if ([transport isEqualToString:LKXTransportUSB] && deviceID) {
        return [NSString stringWithFormat:@"%@:%@:%d", transport, deviceID, port];
    }
    if ([transport isEqualToString:LKXTransportCoreDevice] && deviceIdentifier.length > 0) {
        return [NSString stringWithFormat:@"%@:%@:%d", transport, deviceIdentifier, port];
    }
    return [NSString stringWithFormat:@"%@:%d", transport, port];
}

- (NSString *)_requestKeyForChannel:(Lookin_PTChannel *)channel tag:(uint32_t)tag {
    return [NSString stringWithFormat:@"%d:%u", channel.uniqueID, tag];
}

- (BOOL)_shouldRetryConnectionError:(NSError *)error {
    if (!error) {
        return NO;
    }

    if ([error.domain isEqualToString:NSPOSIXErrorDomain]) {
        return error.code == ECONNREFUSED || error.code == ETIMEDOUT || error.code == ECONNRESET || error.code == ENOTCONN;
    }

    if ([error.domain isEqualToString:Lookin_PTUSBHubErrorDomain]) {
        return error.code == PTUSBHubErrorConnectionRefused;
    }

    return NO;
}

- (NSError * _Nullable)_versionErrorForResponse:(LookinConnectionResponseAttachment *)response {
    int serverVersion = response.lookinServerVersion;
    if (serverVersion > LOOKIN_SUPPORTED_SERVER_MAX || serverVersion < LOOKIN_SUPPORTED_SERVER_MIN) {
        return [self _bridgeErrorWithCode:@"protocol_mismatch" message:[NSString stringWithFormat:@"Unsupported LookinServer protocol version: %d", serverVersion]];
    }
    return nil;
}

- (void)_resolveDetailNodeIDForTarget:(LKXBridgeTarget *)target
                      requestedNodeID:(unsigned long)requestedNodeID
                           completion:(void (^)(unsigned long resolvedNodeID, NSDictionary * _Nullable matchedNode, NSError * _Nullable error))completion {
    NSArray<NSDictionary *> *cachedFlatNodes = self.cachedFlatNodesByTargetID[target.targetID];
    if (cachedFlatNodes.count) {
        NSDictionary *matchedNode = [self _findProjectedNodeInFlatNodes:cachedFlatNodes requestedNodeID:requestedNodeID];
        if (matchedNode) {
            completion([self _detailNodeIDFromProjectedNode:matchedNode fallback:requestedNodeID], matchedNode, nil);
            return;
        }
    }

    [self fetchHierarchyForTarget:target.targetID completion:^(NSDictionary * _Nullable result, NSError * _Nullable error) {
        if (error) {
            completion(requestedNodeID, nil, error);
            return;
        }
        NSArray<NSDictionary *> *flatNodes = [result[@"roots"] isKindOfClass:[NSArray class]] ? self.cachedFlatNodesByTargetID[target.targetID] : nil;
        NSDictionary *matchedNode = [self _findProjectedNodeInFlatNodes:flatNodes requestedNodeID:requestedNodeID];
        completion([self _detailNodeIDFromProjectedNode:matchedNode fallback:requestedNodeID], matchedNode, nil);
    }];
}

- (NSDictionary * _Nullable)_findProjectedNodeInFlatNodes:(NSArray<NSDictionary *> * _Nullable)flatNodes requestedNodeID:(unsigned long)requestedNodeID {
    if (!flatNodes.count) {
        return nil;
    }

    NSNumber *requestedNumber = @(requestedNodeID);
    for (NSDictionary *node in flatNodes) {
        id nodeID = node[@"node_id"];
        id viewOID = node[@"view_oid"];
        id layerOID = node[@"layer_oid"];
        id detailNodeID = node[@"detail_node_id"];
        if (([nodeID isKindOfClass:[NSNumber class]] && [nodeID isEqual:requestedNumber]) ||
            ([viewOID isKindOfClass:[NSNumber class]] && [viewOID isEqual:requestedNumber]) ||
            ([layerOID isKindOfClass:[NSNumber class]] && [layerOID isEqual:requestedNumber]) ||
            ([detailNodeID isKindOfClass:[NSNumber class]] && [detailNodeID isEqual:requestedNumber])) {
            return node;
        }
    }
    return nil;
}

- (unsigned long)_detailNodeIDFromProjectedNode:(NSDictionary * _Nullable)node fallback:(unsigned long)fallback {
    if (![node isKindOfClass:[NSDictionary class]]) {
        return fallback;
    }
    NSNumber *detailNodeID = [node[@"detail_node_id"] isKindOfClass:[NSNumber class]] ? node[@"detail_node_id"] : nil;
    if (detailNodeID.unsignedLongValue > 0) {
        return detailNodeID.unsignedLongValue;
    }
    NSNumber *layerOID = [node[@"layer_oid"] isKindOfClass:[NSNumber class]] ? node[@"layer_oid"] : nil;
    if (layerOID.unsignedLongValue > 0) {
        return layerOID.unsignedLongValue;
    }
    NSNumber *nodeID = [node[@"node_id"] isKindOfClass:[NSNumber class]] ? node[@"node_id"] : nil;
    if (nodeID.unsignedLongValue > 0) {
        return nodeID.unsignedLongValue;
    }
    return fallback;
}

- (void)_mergeMissingBasisVisualInfoIntoDetailPayload:(NSMutableDictionary *)payload
                                      fromMatchedNode:(NSDictionary * _Nullable)matchedNode {
    if (!payload || ![matchedNode isKindOfClass:[NSDictionary class]]) {
        return;
    }

    for (NSString *key in @[@"frame", @"bounds", @"hidden", @"alpha"]) {
        id currentValue = payload[key];
        BOOL shouldFill = currentValue == nil || currentValue == (id)[NSNull null];
        if (!shouldFill) {
            continue;
        }
        id fallbackValue = matchedNode[key];
        if (fallbackValue) {
            payload[key] = fallbackValue;
        }
    }
}

- (NSError *)_connectionErrorForTarget:(LKXBridgeTarget *)target underlyingError:(NSError * _Nullable)error {
    if ([error.domain isEqualToString:NSPOSIXErrorDomain] && error.code == ECONNREFUSED) {
        NSString *host = target.hostAddress.length > 0 ? target.hostAddress : target.hostname;
        NSString *message = host.length > 0
            ? [NSString stringWithFormat:@"The CoreDevice tunnel is reachable at %@:%d, but no LookinServer is listening on that port. Confirm the app is a foreground Debug build with LookinServer integrated.", host, target.port]
            : @"The target app refused the Lookin connection. Confirm the app is a foreground Debug build with LookinServer integrated.";
        return [self _bridgeErrorWithCode:@"connection_refused" message:message];
    }

    if (error.localizedDescription.length > 0) {
        return [self _bridgeErrorWithCode:@"target_not_found" message:error.localizedDescription];
    }

    return [self _bridgeErrorWithCode:@"target_not_found" message:@"Failed to connect to target app."];
}

- (NSError *)_bridgeErrorWithCode:(NSString *)code message:(NSString *)message {
    return [NSError errorWithDomain:@"lookinextension.bridge" code:1 userInfo:@{
        NSLocalizedDescriptionKey: message,
        @"bridge_code": code
    }];
}

- (NSString *)_deviceTypeName:(LookinAppInfoDevice)deviceType {
    switch (deviceType) {
        case LookinAppInfoDeviceSimulator:
            return @"simulator";
        case LookinAppInfoDeviceIPad:
            return @"ipad";
        case LookinAppInfoDeviceOthers:
        default:
            return @"iphone";
    }
}

@end
