#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <sqlite3.h>
#import <stdarg.h>

void BAHUDLog(NSString *fmt, ...);
void BAHUDRefresh(void);
void BAHUDInstall(void);
UIWindow *BAHUDWindow(void);

// ==================== BAConfig ====================
@interface BAConfig : NSObject
@property (copy) NSString *licenseKey, *accountId, *platform, *modelName, *modelAge, *city, *appearance, *hobbies, *ctaInfo, *affiliate;
@property (assign) NSInteger modelId, presetId, activeFrom, activeTo, readDelayMin, readDelayMax, typingMin, typingMax, contactCooldown, pollInterval;
@property (assign) BOOL enabled, dryRun, mediaAutoAttach;
+ (instancetype)shared;
- (void)reload;
- (BOOL)isActiveHour;
@end
@implementation BAConfig
+ (instancetype)shared { static BAConfig *c=nil; static dispatch_once_t once; dispatch_once(&once,^{ c=[BAConfig new]; [c reload]; }); return c; }
- (void)reload {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.he.badooai.plist"] ?: @{};
    self.licenseKey = d[@"licenseKey"]?:@"";
    self.accountId = d[@"accountId"]?:@"badoo-main";
    self.platform = d[@"platform"]?:@"Badoo";
    self.modelId = [d[@"modelId"] integerValue] ?: 43;
    self.presetId = [d[@"presetId"] integerValue] ?: 88;
    self.modelName = d[@"modelName"]?:@"Lily";
    self.modelAge = d[@"modelAge"]?:@"22";
    self.city = d[@"city"]?:@"";
    self.appearance = d[@"appearance"]?:@"";
    self.hobbies = d[@"hobbies"]?:@"";
    self.ctaInfo = d[@"ctaInfo"]?:@"";
    self.affiliate = d[@"affiliate"]?:@"";
    self.enabled = d[@"enabled"] ? [d[@"enabled"] boolValue] : YES;
    self.dryRun = d[@"dryRun"] ? [d[@"dryRun"] boolValue] : YES;
    self.mediaAutoAttach = [d[@"mediaAutoAttach"] boolValue];
    self.activeFrom = [d[@"activeFrom"] integerValue] ?: 8;
    self.activeTo = [d[@"activeTo"] integerValue] ?: 24;
    self.readDelayMin = [d[@"readDelayMin"] integerValue] ?: 4;
    self.readDelayMax = [d[@"readDelayMax"] integerValue] ?: 18;
    self.typingMin = [d[@"typingMin"] integerValue] ?: 22;
    self.typingMax = [d[@"typingMax"] integerValue] ?: 70;
    self.contactCooldown = [d[@"contactCooldown"] integerValue] ?: 900;
    self.pollInterval = [d[@"pollInterval"] integerValue] ?: 3;
}
- (BOOL)isActiveHour {
    NSInteger h = [[NSCalendar currentCalendar] component:NSCalendarUnitHour fromDate:[NSDate date]];
    if (self.activeFrom <= self.activeTo) return h >= self.activeFrom && h < self.activeTo;
    return h >= self.activeFrom || h < self.activeTo;
}
@end

// ==================== BAMessage / BADatabase ====================
@interface BAMessage : NSObject
@property (assign) long long rowid;
@property (assign) long long timestamp;
@property (assign) BOOL incoming;
@property (copy) NSString *text;
@property (copy) NSString *contactKey;
@property (copy) NSString *contactName;
@end
@implementation BAMessage @end

@interface BADatabase : NSObject
@property (copy) NSString *dbPath;
@property (copy) NSString *colText, *colTime, *colConv, *colDir, *onlineCol, *convIdCol;
+ (instancetype)shared;
- (void)locate;
- (NSArray<BAMessage*>*)messagesAfterRowid:(long long)rowid limit:(NSInteger)limit;
- (NSArray<BAMessage*>*)historyForContact:(NSString*)key limit:(NSInteger)limit;
- (BOOL)contactIsOnline:(NSString*)key;
- (long long)maxRowid;
@end

static NSString *ba_findFile(NSString *base, NSString *needle, int depth) {
    if (!base || depth>5) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *items = [fm contentsOfDirectoryAtPath:base error:nil];
    for (NSString *it in items) {
        if ([it.lowercaseString containsString:needle.lowercaseString]) {
            NSString *f = [base stringByAppendingPathComponent:it];
            BOOL d = NO; [fm fileExistsAtPath:f isDirectory:&d];
            if (!d) return f;
        }
    }
    for (NSString *it in items) {
        NSString *f = [base stringByAppendingPathComponent:it];
        BOOL d = NO;
        if (![fm fileExistsAtPath:f isDirectory:&d] || !d) continue;
        NSString *r = ba_findFile(f, needle, depth+1);
        if (r) return r;
    }
    return nil;
}

@implementation BADatabase
+ (instancetype)shared { static BADatabase *s=nil; static dispatch_once_t once; dispatch_once(&once,^{ s=[BADatabase new]; [s locate]; }); return s; }
- (void)locate {
    NSString *home = NSHomeDirectory();
    NSArray *paths = @[
        [home stringByAppendingPathComponent:@"Library/Application Support"],
        [home stringByAppendingPathComponent:@"Documents"],
        [home stringByAppendingPathComponent:@"Library"],
        home
    ];
    for (NSString *p in paths) {
        NSString *f = ba_findFile(p, @"ChatCom", 4);
        if (f) { self.dbPath = f; break; }
    }
    BAHUDLog(@"db: %@", self.dbPath.lastPathComponent ?: @"NOT FOUND");
    [self introspect];
}
- (void)introspect {
    if (!self.dbPath) return;
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(self.dbPath.fileSystemRepresentation, &db, SQLITE_OPEN_READONLY|SQLITE_OPEN_NOMUTEX, NULL) != SQLITE_OK) { if (db) sqlite3_close(db); return; }
    sqlite3_busy_timeout(db, 1500);
    NSMutableArray *c = [NSMutableArray array];
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(db, "PRAGMA table_info(message)", -1, &st, NULL) == SQLITE_OK) {
        while (sqlite3_step(st) == SQLITE_ROW) {
            const char *n = (const char*)sqlite3_column_text(st, 1);
            if (n) [c addObject:@(n)];
        }
    }
    sqlite3_finalize(st);
    for (NSString *w in @[@"payload",@"text",@"body",@"message",@"content"])
        for (NSString *h in c) if ([h.lowercaseString isEqualToString:w]) { self.colText = h; break; }
    for (NSString *w in @[@"created_at",@"timestamp",@"date",@"time"])
        for (NSString *h in c) if ([h.lowercaseString containsString:w]) { if (!self.colTime) self.colTime = h; }
    for (NSString *w in @[@"conversation_id",@"chat_id",@"dialog_id"])
        for (NSString *h in c) if ([h.lowercaseString isEqualToString:w]) { if (!self.colConv) self.colConv = h; }
    for (NSString *w in @[@"is_incoming",@"incoming",@"direction"])
        for (NSString *h in c) if ([h.lowercaseString isEqualToString:w]) { if (!self.colDir) self.colDir = h; }
    sqlite3_close(db);
    BAHUDLog(@"cols text=%@ conv=%@ dir=%@", self.colText, self.colConv, self.colDir);
}
- (sqlite3*)openRO {
    if (!self.dbPath) return NULL;
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(self.dbPath.fileSystemRepresentation, &db, SQLITE_OPEN_READONLY|SQLITE_OPEN_NOMUTEX, NULL) != SQLITE_OK) { if (db) sqlite3_close(db); return NULL; }
    sqlite3_busy_timeout(db, 1500);
    return db;
}
- (long long)maxRowid {
    sqlite3 *db = [self openRO]; if (!db) return 0;
    long long v = 0; sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(db, "SELECT MAX(rowid) FROM message", -1, &st, NULL) == SQLITE_OK) {
        if (sqlite3_step(st) == SQLITE_ROW) v = sqlite3_column_int64(st, 0);
    }
    sqlite3_finalize(st); sqlite3_close(db);
    return v;
}
- (NSString*)txt:(sqlite3_stmt*)st idx:(int)i {
    const unsigned char *c = sqlite3_column_text(st, i);
    if (!c) return nil;
    NSString *s = [NSString stringWithUTF8String:(const char*)c];
    return s ?: [[NSString alloc] initWithBytes:c length:(NSUInteger)sqlite3_column_bytes(st, i) encoding:NSISOLatin1StringEncoding];
}
- (BOOL)incoming:(sqlite3_stmt*)st dir:(int)d {
    if (d < 0) return YES;
    if (sqlite3_column_type(st, d) == SQLITE_TEXT) {
        NSString *v = [self txt:st idx:d].lowercaseString;
        if ([v containsString:@"in"]) return YES;
        if ([v containsString:@"out"]) return NO;
    }
    return sqlite3_column_int(st, d) != 0;
}
- (long long)normTime:(long long)raw {
    if (raw <= 0) return (long long)[NSDate date].timeIntervalSince1970;
    if (raw > 100000000000LL) return raw / 1000;
    if (raw > 1000000000LL) return raw;
    return (long long)[NSDate date].timeIntervalSince1970;
}
- (NSArray*)messagesAfterRowid:(long long)rid limit:(NSInteger)lim {
    sqlite3 *db = [self openRO]; if (!db) return @[];
    NSString *sql = [NSString stringWithFormat:@"SELECT rowid, %@, %@, %@, %@ FROM message WHERE rowid>%lld ORDER BY rowid ASC LIMIT %ld", self.colText?:@"''", self.colTime?:@"0", self.colConv?:@"''", self.colDir?:@"1", rid, (long)lim];
    sqlite3_stmt *st = NULL; NSMutableArray *out = [NSMutableArray array];
    if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &st, NULL) == SQLITE_OK) {
        while (sqlite3_step(st) == SQLITE_ROW) {
            BAMessage *m = [BAMessage new];
            m.rowid = sqlite3_column_int64(st, 0);
            m.text = [self txt:st idx:1] ?: @"";
            m.timestamp = [self normTime:sqlite3_column_int64(st, 2)];
            m.contactKey = [self txt:st idx:3] ?: @"unknown";
            m.incoming = [self incoming:st dir:3];
            if (m.text.length) [out addObject:m];
        }
    }
    sqlite3_finalize(st); sqlite3_close(db);
    return out;
}
- (NSArray*)historyForContact:(NSString*)key limit:(NSInteger)lim {
    sqlite3 *db = [self openRO]; if (!db) return @[];
    NSString *sql = [NSString stringWithFormat:@"SELECT %@, %@, %@ FROM message WHERE %@=? ORDER BY rowid DESC LIMIT %ld", self.colText?:@"''", self.colTime?:@"0", self.colDir?:@"1", self.colConv?:@"''", (long)lim];
    sqlite3_stmt *st = NULL; NSMutableArray *out = [NSMutableArray array];
    if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &st, NULL) == SQLITE_OK) {
        sqlite3_bind_text(st, 1, key.UTF8String, -1, SQLITE_TRANSIENT);
        while (sqlite3_step(st) == SQLITE_ROW) {
            BAMessage *m = [BAMessage new];
            m.text = [self txt:st idx:0] ?: @"";
            m.timestamp = [self normTime:sqlite3_column_int64(st, 1)];
            m.incoming = [self incoming:st dir:2];
            m.contactKey = key;
            if (m.text.length) [out addObject:m];
        }
    }
    sqlite3_finalize(st); sqlite3_close(db);
    return [[out reverseObjectEnumerator] allObjects];
}
- (BOOL)contactIsOnline:(NSString*)key { return NO; }
@end

// ==================== BACapitalAI ====================
typedef void (^BAReplyBlock)(NSArray<NSDictionary*> *content, NSDictionary *flags);

@interface BACapitalAI : NSObject
+ (instancetype)shared;
- (void)replyForContact:(NSString*)k name:(NSString*)n history:(NSArray<BAMessage*>*)h completion:(BAReplyBlock)c;
@end
@implementation BACapitalAI
+ (instancetype)shared { static BACapitalAI *s=nil; static dispatch_once_t once; dispatch_once(&once,^{ s=[BACapitalAI new]; }); return s; }
- (void)replyForContact:(NSString*)k name:(NSString*)n history:(NSArray<BAMessage*>*)h completion:(BAReplyBlock)c {
    BAConfig *cfg = [BAConfig shared];
    if (!cfg.licenseKey.length) { c(@[], @{@"error":@"no_key"}); return; }
    NSMutableArray *ch = [NSMutableArray array];
    for (BAMessage *m in h) {
        [ch addObject:@{@"role": m.incoming?@"user":@"assistant", @"content": m.text, @"timestamp": @(m.timestamp)}];
    }
    NSMutableDictionary *body = [@{
        @"licensekey": cfg.licenseKey,
        @"modelId": @(cfg.modelId),
        @"presetId": @(cfg.presetId),
        @"accountId": cfg.accountId,
        @"platform": cfg.platform,
        @"modelName": cfg.modelName,
        @"modelAge": cfg.modelAge,
        @"chatHistory": ch,
        @"userInfos": @{@"useridentifier": k, @"name": n?:@""}
    } mutableCopy];
    if (cfg.city.length) body[@"city"] = cfg.city;
    if (cfg.appearance.length) body[@"appearance"] = cfg.appearance;
    if (cfg.hobbies.length) body[@"hobbies"] = cfg.hobbies;
    if (cfg.ctaInfo.length) body[@"ctaInfo"] = cfg.ctaInfo;
    if (cfg.affiliate.length) body[@"affiliate"] = cfg.affiliate;

    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://api.capitalbot.ai/generateResponse"]];
    r.HTTPMethod = @"POST";
    [r setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    r.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    r.timeoutInterval = 45;

    [[NSURLSession.sharedSession dataTaskWithRequest:r completionHandler:^(NSData *d, NSURLResponse *rp, NSError *e) {
        if (e || !d) { c(@[], @{@"error": e.localizedDescription?:@"net"}); return; }
        NSDictionary *root = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        if (![root isKindOfClass:[NSDictionary class]]) { c(@[], @{@"error":@"json"}); return; }
        NSMutableDictionary *f = [NSMutableDictionary dictionary];
        for (NSString *kk in @[@"converted",@"underage",@"timewaste",@"tierFiltered",@"genderFiltered",@"aiCreditOver",@"messagedAlready",@"internalAccount",@"ignored",@"ppvExhausted",@"chatCooldown",@"sellingMode",@"chatCooldownUntil"])
            if (root[kk]) f[kk] = root[kk];
        NSArray *content = root[@"content"];
        if (![content isKindOfClass:[NSArray class]]) content = root[@"messages"];
        if (![content isKindOfClass:[NSArray class]]) content = @[];
        NSMutableArray *clean = [NSMutableArray array];
        for (id it in content)
            if ([it isKindOfClass:[NSDictionary class]] && it[@"type"] && it[@"content"]) [clean addObject:it];
        c(clean, f);
    }] resume];
}
@end

// ==================== BAUI ====================
static BOOL ba_nameMatch(id o, NSString *needle, int d, NSMutableSet *seen) {
    if (!o || d>4 || needle.length<2) return NO;
    if (!seen) seen = [NSMutableSet set];
    NSString *ptr = [NSString stringWithFormat:@"%p", o];
    if ([seen containsObject:ptr]) return NO;
    [seen addObject:ptr];
    if ([o isKindOfClass:[NSString class]]) return [(NSString*)o rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound;
    if ([o isKindOfClass:[NSNumber class]] || [o isKindOfClass:[NSDate class]]) return NO;
    if ([o isKindOfClass:[NSArray class]]) {
        for (id v in o) if (ba_nameMatch(v, needle, d+1, seen)) return YES;
        return NO;
    }
    Class w = object_getClass(o); int lvl = 0;
    while (w && lvl<3) {
        unsigned int ic = 0; Ivar *iv = class_copyIvarList(w, &ic);
        BOOL hit = NO;
        for (unsigned int i=0;i<ic&&!hit;i++) {
            const char *t = ivar_getTypeEncoding(iv[i]);
            if (!t||t[0]!='@') continue;
            id v = nil; @try { v = object_getIvar(o, iv[i]); } @catch(id e){continue;}
            if (v && ba_nameMatch(v, needle, d+1, seen)) hit = YES;
        }
        if (iv) free(iv);
        if (hit) return YES;
        w = class_getSuperclass(w); lvl++;
    }
    return NO;
}
static void ba_walk(UIView *v, void(^b)(UIView*)) { if (!v) return; b(v); for (UIView *s in v.subviews) ba_walk(s, b); }
static UITableView *ba_findTV(UIView *r) { __block UITableView *f=nil; ba_walk(r, ^(UIView *v){ if (!f && [v isKindOfClass:[UITableView class]] && ((UITableView*)v).numberOfSections>0) f=(UITableView*)v; }); return f; }
static UICollectionView *ba_findCV(UIView *r) { __block UICollectionView *f=nil; ba_walk(r, ^(UIView *v){ if (!f && [v isKindOfClass:[UICollectionView class]]) f=(UICollectionView*)v; }); return f; }
static UITextView *ba_findInput(UIView *r) {
    __block UITextView *best=nil; __block CGFloat bestY=-1;
    ba_walk(r, ^(UIView *v){
        if (![v isKindOfClass:[UITextView class]]) return;
        UITextView *tv=(UITextView*)v;
        if (!tv.isEditable || tv.isHidden || tv.alpha<0.1) return;
        CGRect ir=[tv convertRect:tv.bounds toView:nil];
        if (ir.origin.y>bestY) { bestY=ir.origin.y; best=tv; }
    });
    return best;
}
static UIButton *ba_findSend(UIView *r, CGFloat inputY) {
    __block UIButton *best=nil; __block CGFloat bestScore=-1;
    ba_walk(r, ^(UIView *v){
        if (![v isKindOfClass:[UIButton class]]) return;
        UIButton *b=(UIButton*)v;
        if (b.isHidden || b.alpha<0.1 || !b.userInteractionEnabled) return;
        CGRect ir=[b convertRect:b.bounds toView:nil];
        if (ir.origin.y < inputY-40) return;
        if (ir.size.width<18 || ir.size.height<18) return;
        NSString *lbl=[NSString stringWithFormat:@"%@ %@", b.accessibilityLabel?:@"", b.accessibilityIdentifier?:@""].lowercaseString;
        BOOL named = [lbl containsString:@"send"];
        CGFloat sc = named ? 10000 : ir.origin.x;
        if (sc>bestScore) { bestScore=sc; best=b; }
    });
    return best;
}

@interface BAUI : NSObject
+ (instancetype)shared;
- (UIViewController*)topVC;
- (BOOL)openChat:(NSString*)name ident:(NSString*)ident;
- (BOOL)typeAndSend:(NSString*)text;
- (void)goBack;
@end
@implementation BAUI
+ (instancetype)shared { static BAUI *s=nil; static dispatch_once_t once; dispatch_once(&once,^{ s=[BAUI new]; }); return s; }
- (UIViewController*)topVC {
    UIWindow *kw=nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene*)s).windows)
            if (w.isKeyWindow && w != BAHUDWindow()) { kw=w; break; }
        if (kw) break;
    }
    UIViewController *vc = kw.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if ([vc isKindOfClass:[UINavigationController class]]) vc = ((UINavigationController*)vc).topViewController;
    if ([vc isKindOfClass:[UITabBarController class]]) vc = ((UITabBarController*)vc).selectedViewController;
    return vc;
}
- (BOOL)openChat:(NSString*)name ident:(NSString*)ident {
    UIViewController *vc = [self topVC];
    UITableView *tv = ba_findTV(vc.view);
    UICollectionView *cv = ba_findCV(vc.view);
    if (!tv && !cv) return NO;
    NSString *needle = name.length>=2 ? name : ident;
    if (needle.length<2) return NO;
    for (int pg=0; pg<6; pg++) {
        if (tv) {
            for (NSInteger s=0;s<tv.numberOfSections;s++)
                for (NSInteger r=0;r<[tv numberOfRowsInSection:s];r++) {
                    NSIndexPath *ip=[NSIndexPath indexPathForRow:r inSection:s];
                    UITableViewCell *c=[tv cellForRowAtIndexPath:ip];
                    if (c && ba_nameMatch(c, needle, 0, nil)) {
                        [tv selectRowAtIndexPath:ip animated:NO scrollPosition:UITableViewScrollPositionMiddle];
                        id<UITableViewDelegate> d=tv.delegate;
                        if ([d respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)])
                            [d tableView:tv didSelectRowAtIndexPath:ip];
                        return YES;
                    }
                }
            [tv setContentOffset:CGPointMake(0, tv.contentOffset.y+tv.bounds.size.height*0.8) animated:NO];
        } else if (cv) {
            for (NSInteger s=0;s<cv.numberOfSections;s++)
                for (NSInteger i=0;i<[cv numberOfItemsInSection:s];i++) {
                    NSIndexPath *ip=[NSIndexPath indexPathForItem:i inSection:s];
                    UICollectionViewCell *c=[cv cellForItemAtIndexPath:ip];
                    if (c && ba_nameMatch(c, needle, 0, nil)) {
                        [cv selectItemAtIndexPath:ip animated:NO scrollPosition:UICollectionViewScrollPositionCenteredVertically];
                        id<UICollectionViewDelegate> d=cv.delegate;
                        if ([d respondsToSelector:@selector(collectionView:didSelectItemAtIndexPath:)])
                            [d collectionView:cv didSelectItemAtIndexPath:ip];
                        return YES;
                    }
                }
            [cv setContentOffset:CGPointMake(0, cv.contentOffset.y+cv.bounds.size.height*0.8) animated:NO];
        }
        [NSThread sleepForTimeInterval:0.25];
    }
    return NO;
}
- (BOOL)typeAndSend:(NSString*)text {
    if (!text.length) return NO;
    UIViewController *vc = [self topVC];
    UITextView *input = ba_findInput(vc.view);
    if (!input) return NO;
    CGRect ir = [input convertRect:input.bounds toView:nil];
    dispatch_async(dispatch_get_main_queue(), ^{
        input.text = @"";
        [input becomeFirstResponder];
        if ([input.delegate respondsToSelector:@selector(textViewDidChange:)]) [input.delegate textViewDidChange:input];
        [[NSNotificationCenter defaultCenter] postNotificationName:UITextViewTextDidChangeNotification object:input];
    });
    [NSThread sleepForTimeInterval:0.4];
    for (NSUInteger i=0;i<text.length;i++) {
        NSString *ch=[text substringWithRange:NSMakeRange(i,1)];
        dispatch_async(dispatch_get_main_queue(), ^{
            input.text=[input.text stringByAppendingString:ch];
            if ([input.delegate respondsToSelector:@selector(textViewDidChange:)]) [input.delegate textViewDidChange:input];
            [[NSNotificationCenter defaultCenter] postNotificationName:UITextViewTextDidChangeNotification object:input];
        });
        NSUInteger p = 35 + arc4random_uniform(85);
        if ([ch isEqualToString:@" "] && arc4random_uniform(100)<12) p += 250 + arc4random_uniform(600);
        [NSThread sleepForTimeInterval:p/1000.0];
    }
    [NSThread sleepForTimeInterval:0.3];
    UIButton *s = ba_findSend(vc.view, ir.origin.y);
    if (!s) return NO;
    dispatch_async(dispatch_get_main_queue(), ^{ [s sendActionsForControlEvents:UIControlEventTouchUpInside]; });
    [NSThread sleepForTimeInterval:0.5];
    return YES;
}
- (void)goBack {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc=[self topVC];
        if (vc.navigationController && vc.navigationController.viewControllers.count>1) {
            [vc.navigationController popViewControllerAnimated:NO]; return;
        }
        [vc dismissViewControllerAnimated:NO completion:nil];
    });
}
@end

// ==================== BAEngine ====================
@interface BAEngine : NSObject
+ (instancetype)shared;
- (void)start;
- (void)setPaused:(BOOL)p;
- (BOOL)paused;
- (NSUInteger)queueDepth;
- (NSString*)statusLine;
@end
@implementation BAEngine {
    dispatch_queue_t _q;
    NSMutableArray<BAMessage*> *_queue;
    NSMutableSet<NSString*> *_inflight;
    NSMutableDictionary<NSString*, NSDate*> *_cooldowns;
    NSMutableDictionary<NSString*, NSNumber*> *_pausedUntil;
    NSMutableSet<NSString*> *_sent;
    long long _lastRowid;
    BOOL _paused;
    NSString *_status;
}
+ (instancetype)shared { static BAEngine *e=nil; static dispatch_once_t once; dispatch_once(&once,^{ e=[BAEngine new]; }); return e; }
- (instancetype)init {
    if ((self=[super init])) {
        _q = dispatch_queue_create("he.badooai.engine", DISPATCH_QUEUE_SERIAL);
        _queue=[NSMutableArray array]; _inflight=[NSMutableSet set];
        _cooldowns=[NSMutableDictionary dictionary]; _pausedUntil=[NSMutableDictionary dictionary];
        _sent=[NSMutableSet set]; _status=@"idle";
    }
    return self;
}
- (void)start {
    _lastRowid = [[BADatabase shared] maxRowid];
    BAHUDLog(@"engine start rid=%lld", _lastRowid);
    __weak typeof(self) w=self;
    dispatch_source_t t=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_global_queue(QOS_CLASS_UTILITY,0));
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW,0),(uint64_t)(MAX(2,[BAConfig shared].pollInterval)*NSEC_PER_SEC), 1*NSEC_PER_SEC);
    dispatch_source_set_event_handler(t, ^{ [w poll]; });
    dispatch_resume(t);
}
- (void)setPaused:(BOOL)p { _paused=p; _status=p?@"paused":@"idle"; BAHUDRefresh(); }
- (BOOL)paused { return _paused; }
- (NSUInteger)queueDepth { return _queue.count; }
- (NSString*)statusLine { return _status?:@"idle"; }
- (void)poll {
    if (_paused) return;
    BAConfig *cfg=[BAConfig shared];
    if (!cfg.enabled || ![cfg isActiveHour]) return;
    NSArray *fresh=[[BADatabase shared] messagesAfterRowid:_lastRowid limit:50];
    if (!fresh.count) return;
    for (BAMessage *m in fresh) {
        if (m.rowid>_lastRowid) _lastRowid=m.rowid;
        if (!m.incoming) continue;
        if ([_sent containsObject:m.text]) continue;
        if ([_pausedUntil[m.contactKey] doubleValue] > [NSDate date].timeIntervalSince1970) continue;
        BOOL dup=NO;
        for (BAMessage *q in _queue) if ([q.contactKey isEqualToString:m.contactKey]) { dup=YES; break; }
        if (dup) continue;
        [_queue addObject:m];
    }
    BAHUDRefresh();
    [self drain];
}
- (void)drain {
    if (_paused) return;
    BAMessage *job=nil;
    for (BAMessage *m in _queue) if (![_inflight containsObject:m.contactKey]) { job=m; break; }
    if (!job) return;
    [_queue removeObject:job];
    [_inflight addObject:job.contactKey];
    __weak typeof(self) w=self;
    dispatch_async(_q, ^{ [w process:job]; });
}
- (void)process:(BAMessage*)job {
    @autoreleasepool {
        BAConfig *cfg=[BAConfig shared];
        BADatabase *db=[BADatabase shared];
        self->_status = [NSString stringWithFormat:@"reply %@", job.contactKey];
        BAHUDRefresh();
        NSInteger rd=cfg.readDelayMin + arc4random_uniform((uint32_t)MAX(1, cfg.readDelayMax-cfg.readDelayMin+1));
        [NSThread sleepForTimeInterval:rd];
        NSArray *hist=[db historyForContact:job.contactKey limit:40];
        __block BOOL done=NO;
        __weak typeof(self) weakSelf=self;
        [[BACapitalAI shared] replyForContact:job.contactKey name:job.contactName?:@"" history:hist completion:^(NSArray<NSDictionary*>*content, NSDictionary*flags) {
            @autoreleasepool {
                if ([flags[@"underage"] boolValue] || [flags[@"ignored"] boolValue] || [flags[@"internalAccount"] boolValue] || [flags[@"tierFiltered"] boolValue] || [flags[@"genderFiltered"] boolValue] || [flags[@"ppvExhausted"] boolValue]) {
                    [weakSelf pauseC:job.contactKey s:86400]; done=YES; return;
                }
                if ([flags[@"aiCreditOver"] boolValue]) { [weakSelf setPaused:YES]; done=YES; return; }
                if ([flags[@"converted"] boolValue]) { [weakSelf pauseC:job.contactKey s:3600]; done=YES; return; }
                if (!content.count) { done=YES; return; }
                if (cfg.dryRun) {
                    NSMutableString *pv=[NSMutableString string];
                    for (NSDictionary *p in content) [pv appendFormat:@"[%@] %@\n", p[@"type"], p[@"content"]];
                    BAHUDLog(@"DRY: %@", pv);
                    done=YES; return;
                }
                if (![[BAUI shared] openChat:job.contactName ident:job.contactKey]) {
                    BAHUDLog(@"open failed %@", job.contactKey);
                    [weakSelf pauseC:job.contactKey s:300]; done=YES; return;
                }
                [NSThread sleepForTimeInterval:1.0];
                for (NSDictionary *p in content) {
                    NSString *ty=p[@"type"], *vl=p[@"content"];
                    if ([ty isEqualToString:@"text"]) {
                        NSUInteger ms=cfg.typingMin + arc4random_uniform((uint32_t)MAX(1, cfg.typingMax-cfg.typingMin+1));
                        double base=MIN(9.0, MAX(1.5, vl.length*(ms/1000.0)/5.0));
                        [NSThread sleepForTimeInterval:base];
                        [weakSelf->_sent addObject:vl];
                        [[BAUI shared] typeAndSend:vl];
                        [NSThread sleepForTimeInterval:1.2 + arc4random_uniform(2000)/1000.0];
                    }
                }
                [[BAUI shared] goBack];
                [NSThread sleepForTimeInterval:0.8];
                done=YES;
            }
        }];
        NSDate *dl=[NSDate dateWithTimeIntervalSinceNow:60];
        while (!done && [dl timeIntervalSinceNow]>0) [NSThread sleepForTimeInterval:0.1];
        self->_cooldowns[job.contactKey]=[NSDate dateWithTimeIntervalSinceNow:cfg.contactCooldown];
        [_inflight removeObject:job.contactKey];
        self->_status=@"idle";
        BAHUDRefresh();
    }
}
- (void)pauseC:(NSString*)k s:(double)s { _pausedUntil[k]=@([NSDate date].timeIntervalSince1970+s); }
@end

// ==================== BAHUD ====================
static UIWindow *gHUDWindow = nil;
static UILabel *gHUDLabel = nil;

UIWindow *BAHUDWindow(void) { return gHUDWindow; }

void BAHUDLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *m = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[BadooAI] %@", m);
}
void BAHUDRefresh(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gHUDLabel) return;
        BAEngine *e = [BAEngine shared];
        gHUDLabel.text = [NSString stringWithFormat:@"%@ q%lu", e.paused?@"PAUSED":e.statusLine, (unsigned long)e.queueDepth];
        gHUDLabel.backgroundColor = e.paused
            ? [UIColor colorWithRed:0.6 green:0.2 blue:0.1 alpha:0.9]
            : [UIColor colorWithRed:0.05 green:0.45 blue:0.35 alpha:0.9];
    });
}
@interface BA_HUDVC : UIViewController @end
@implementation BA_HUDVC
- (void)viewDidLoad { [super viewDidLoad]; self.view.backgroundColor = UIColor.clearColor; }
@end
void BAHUDInstall(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(3*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gHUDWindow) return;
        UIWindowScene *sc = nil;
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
            if ([s isKindOfClass:[UIWindowScene class]]) { sc=(UIWindowScene*)s; break; }
        gHUDWindow = sc ? [[UIWindow alloc] initWithWindowScene:sc] : [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        gHUDWindow.windowLevel = UIWindowLevelAlert + 101;
        gHUDWindow.backgroundColor = UIColor.clearColor;
        gHUDWindow.rootViewController = [BA_HUDVC new];
        gHUDWindow.hidden = NO;
        gHUDLabel = [[UILabel alloc] initWithFrame:CGRectMake(0,0,150,32)];
        gHUDLabel.text = @"AI: idle";
        gHUDLabel.textAlignment = NSTextAlignmentCenter;
        gHUDLabel.font = [UIFont boldSystemFontOfSize:10];
        gHUDLabel.textColor = UIColor.whiteColor;
        gHUDLabel.backgroundColor = [UIColor colorWithRed:0.05 green:0.45 blue:0.35 alpha:0.9];
        gHUDLabel.layer.cornerRadius = 8;
        gHUDLabel.layer.masksToBounds = YES;
        gHUDLabel.userInteractionEnabled = YES;
        gHUDLabel.center = CGPointMake(UIScreen.mainScreen.bounds.size.width-90, 120);
        [gHUDWindow addSubview:gHUDLabel];
        class_addMethod([UILabel class], NSSelectorFromString(@"ba_tap"),
            imp_implementationWithBlock(^(UILabel *v){ [[BAEngine shared] setPaused:![BAEngine shared].paused]; }), "v@:");
        [gHUDLabel addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:gHUDLabel action:NSSelectorFromString(@"ba_tap")]];
        BAHUDRefresh();
    });
}

// ==================== Entry ====================
%ctor {
    @autoreleasepool {
        NSLog(@"[BadooAI] loaded");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(5*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[BAConfig shared] reload];
            BAHUDInstall();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(2*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [[BAEngine shared] start];
            });
        });
    }
}
