#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LKXBridgeService : NSObject

@property(nonatomic, assign) BOOL persistentConnectionsEnabled;

- (void)listTargetsWithCompletion:(void (^)(NSArray<NSDictionary *> * _Nullable targets, NSError * _Nullable error))completion;
- (void)listSessionsWithCompletion:(void (^)(NSArray<NSDictionary *> * _Nullable sessions, NSError * _Nullable error))completion;
- (void)createSessionForTarget:(NSString *)targetID completion:(void (^)(NSDictionary * _Nullable session, NSError * _Nullable error))completion;
- (void)deleteSession:(NSString *)sessionID completion:(void (^)(NSDictionary * _Nullable result, NSError * _Nullable error))completion;
- (void)listSnapshotsForSession:(NSString * _Nullable)sessionID completion:(void (^)(NSArray<NSDictionary *> * _Nullable snapshots, NSError * _Nullable error))completion;
- (void)captureSnapshotForSession:(NSString *)sessionID
                             name:(NSString * _Nullable)name
                          options:(NSDictionary * _Nullable)options
                       completion:(void (^)(NSDictionary * _Nullable snapshot, NSError * _Nullable error))completion;
- (void)diffSnapshotsForSession:(NSString *)sessionID
                      snapshotA:(NSString *)snapshotAID
                      snapshotB:(NSString *)snapshotBID
                     completion:(void (^)(NSDictionary * _Nullable diff, NSError * _Nullable error))completion;
- (void)pingTarget:(NSString * _Nullable)targetID
         sessionID:(NSString * _Nullable)sessionID
        completion:(void (^)(NSDictionary * _Nullable result, NSError * _Nullable error))completion;
- (void)fetchHierarchyForTarget:(NSString * _Nullable)targetID
                      sessionID:(NSString * _Nullable)sessionID
                        options:(NSDictionary * _Nullable)options
                     completion:(void (^)(NSDictionary * _Nullable result, NSError * _Nullable error))completion;
- (void)findNodesForTarget:(NSString * _Nullable)targetID
                  sessionID:(NSString * _Nullable)sessionID
                     query:(NSDictionary *)query
                completion:(void (^)(NSDictionary * _Nullable result, NSError * _Nullable error))completion;
- (void)fetchObjectForTarget:(NSString * _Nullable)targetID
                   sessionID:(NSString * _Nullable)sessionID
                      nodeID:(unsigned long)nodeID
                  completion:(void (^)(NSDictionary * _Nullable result, NSError * _Nullable error))completion;
- (void)fetchViewDetailsForTarget:(NSString * _Nullable)targetID
                        sessionID:(NSString * _Nullable)sessionID
                           nodeID:(unsigned long)nodeID
                    screenshotMode:(NSString * _Nullable)screenshotMode
                   includeSubitems:(BOOL)includeSubitems
                        completion:(void (^)(NSDictionary * _Nullable result, NSError * _Nullable error))completion;
- (void)fetchScreenshotForTarget:(NSString * _Nullable)targetID
                       sessionID:(NSString * _Nullable)sessionID
                          nodeID:(NSNumber * _Nullable)nodeID
                            mode:(NSString * _Nullable)mode
                      completion:(void (^)(NSDictionary * _Nullable result, NSError * _Nullable error))completion;

- (void)pingTarget:(NSString *)targetID completion:(void (^)(NSDictionary * _Nullable result, NSError * _Nullable error))completion;
- (void)fetchHierarchyForTarget:(NSString *)targetID completion:(void (^)(NSDictionary * _Nullable result, NSError * _Nullable error))completion;
- (void)findNodesForTarget:(NSString *)targetID
                     query:(NSDictionary *)query
                completion:(void (^)(NSDictionary * _Nullable result, NSError * _Nullable error))completion;
- (void)fetchObjectForTarget:(NSString *)targetID
                      nodeID:(unsigned long)nodeID
                  completion:(void (^)(NSDictionary * _Nullable result, NSError * _Nullable error))completion;
- (void)fetchViewDetailsForTarget:(NSString *)targetID
                           nodeID:(unsigned long)nodeID
                    screenshotMode:(NSString * _Nullable)screenshotMode
                   includeSubitems:(BOOL)includeSubitems
                        completion:(void (^)(NSDictionary * _Nullable result, NSError * _Nullable error))completion;
- (void)fetchScreenshotForTarget:(NSString *)targetID
                          nodeID:(NSNumber * _Nullable)nodeID
                            mode:(NSString * _Nullable)mode
                      completion:(void (^)(NSDictionary * _Nullable result, NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
