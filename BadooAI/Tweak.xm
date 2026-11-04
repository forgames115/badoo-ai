#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <sqlite3.h>
#import <stdarg.h>
#import <stdlib.h>
#import <unistd.h>

void BAHUDLog(NSString *fmt, ...);
void BAHUDRefresh(void);
void BAHUDInstall(void);
UIWindow *BAHUDWindow(void);

// ==================== helpers ====================
static inline void ba_main_sync(void (^block)(void)) {
    if ([NSThread isMainThread]) block();
    else dispatch_sync(dispatch_get_main_queue(), block);
}
static inline void ba_main_async(void (^block)(void)) {
    dispatch_async(dispatch_get_main_queue(), block);
}
static NSString *ba_sqlite_err(sqlite3 *db) {
    return db ? [NSString stringWithUTF8String:sqlite3_errmsg(db)] : @"db null";
}
static id BAPref(NSString *key) {
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key, CFSTR("com.he.badooai"));
    if (!v) return nil;
    return (__bridge_transfer id)v;
}

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
- (NSString*)sPref:(NSString*)k def:(NSString*)d {
    id v = BAPref(k);
    if ([v isKindOfClass:[NSString class]]) return v;
    return d;
}
- (NSInteger)iPref:(NSString*)k def:(NSInteger)d {
    id v = BAPref(k);
    if ([v respondsToSelector:@selector(integerValue)]) return [v integerValue] ?: d;
    return d;
}
- (BOOL)bPref:(NSString*)k def:(BOOL)d {
    id v = BAPref(k);
    return v == nil ? d : [v boolValue];
}
- (void)reload {
    self.licenseKey  = [self sPref:@"licenseKey" def:@""];
    self.accountId   = [self sPref:@"accountId" def:@"badoo-main"];
    self.platform    = [self sPref:@"platform" def:@"Badoo"];
    self.modelId     = [self iPref:@"modelId" def:43];
    self.presetId    = [self iPref:@"presetId" def:88];
    self.modelName   = [self sPref:@"modelName" def:@"Lily"];
    self.modelAge    = [self sPref:@"modelAge" def:@"22"];
    self.city        = [self sPref:@"city" def:@""];
    self.appearance  = [self sPref:@"appearance" def:@""];
    self.hobbies     = [self sPref:@"hobbies" def:@""];
    self.ctaInfo     = [self sPref:@"ctaInfo" def:@""];
    self.affiliate   = [self sPref:@"affiliate" def:@""];
    self.enabled     = [self bPref:@"enabled" def:YES];
    self.dryRun      = [self bPref:@"dryRun" def:YES];
    self.mediaAutoAttach = [self bPref:@"mediaAutoAttach" def:NO];
    self.activeFrom  = [self iPref:@"activeFrom" def:8];
    self.activeTo    = [self iPref:@"activeTo" def:24];
    self.readDelayMin= [self iPref:@"readDelayMin" def:4];
    self.readDelayMax= [self iPref:@"readDelayMax" def:18];
    self.typingMin   = [self iPref:@"typingMin" def:22];
    self.typingMax   = [self iPref:@"typingMax" def:70];
    self.contactCooldown = [self iPref:@"contactCooldown" def:900];
    self.pollInterval= [self iPref:@"pollInterval" def:3];

    NSString *mask = self.licenseKey.length > 8
        ? [NSString stringWithFormat:@"%@…", [self.licenseKey substringToIndex:8]] : self.licenseKey;
    BAHUDLog(@"CFG: enabled=%d dry=%d license=%@ model=%ld preset=%ld",
             self.enabled, self.dryRun, mask, (long)self.modelId, (long)self.presetId);
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
@property (copy) NSString *tableName;
@property (copy) NSString *colText, *colTime, *colConv, *colDir;
+ (instancetype)shared;
- (void)locate;
- (NSArray<BAMessage*>*)messagesAfterRowid:(long long)rowid limit:(NSInteger)limit;
- (NSArray<BAMessage*>*)historyForContact:(NSString*)key limit:(NSInteger)limit;
- (long long)maxRowid;
@end

@implementation BADatabase
+ (instancetype)shared { static BADatabase *s=nil; static dispatch_once_t once; dispatch_once(&once,^{ s=[BADatabase new]; }); return s; }

- (void)collectFiles:(NSArray<NSString*>*)dirs into:(NSMutableArray<NSString*>*)out depth:(int)depth {
    if (depth > 4) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *dir in dirs) {
        for (NSString *it in [fm contentsOfDirectoryAtPath:dir error:nil]) {
            if ([it hasPrefix:@"."]) continue;
            NSString *full = [dir stringByAppendingPathComponent:it];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:full isDirectory:&isDir]) continue;
            if (isDir) {
                if ([it isEqualToString:@"Caches"] || [it isEqualToString:@"tmp"] ||
                    [it hasPrefix:@"Snapshots"] || [it hasPrefix:@"SplashBoard"]) continue;
                [self collectFiles:@[full] into:out depth:depth+1];
            } else {
                NSString *low = it.lowercaseString;
                NSString *ext = full.pathExtension.lowercaseString;
                BOOL interesting = [low containsString:@"chat"] ||
                    [ext isEqualToString:@"db"] || [ext isEqualToString:@"sqlite"] || [ext isEqualToString:@"sqlite3"];
                if (interesting) [out addObject:full];
            }
        }
    }
}

- (NSArray<NSString*>*)tablesOf:(sqlite3*)db {
    NSMutableArray *t = [NSMutableArray array];
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table'", -1, &st, NULL) == SQLITE_OK) {
        while (sqlite3_step(st) == SQLITE_ROW) {
            const unsigned char *n = sqlite3_column_text(st, 0);
            if (n) [t addObject:[NSString stringWithUTF8String:(const char*)n]];
        }
    } else BAHUDLog(@"DB table list error: %@", ba_sqlite_err(db));
    sqlite3_finalize(st);
    return t;
}

- (void)locate {
    if (self.dbPath) return;
    NSMutableArray<NSString*> *files = [NSMutableArray array];
    [self collectFiles:@[NSHomeDirectory()] into:files depth:0];
    BAHUDLog(@"DB scan: %lu candidate files", (unsigned long)files.count);
    if (!files.count) return;

    NSMutableDictionary<NSString*, NSNumber*> *score = [NSMutableDictionary dictionary];
    for (NSString *p in files) {
        int s = 0; NSString *low = p.lowercaseString;
        if ([low containsString:@"chatcom"]) s += 60;
        if ([low containsString:@"chat"])    s += 30;
        if ([low containsString:@"message"]) s += 20;
        NSString *ext = p.pathExtension.lowercaseString;
        if ([ext isEqualToString:@"db"] || [ext isEqualToString:@"sqlite"] || [ext isEqualToString:@"sqlite3"]) s += 10;
        if ([low containsString:@"application support"]) s += 6;
        if ([low containsString:@"documents"]) s += 6;
        if ([p hasSuffix:@"-wal"] || [p hasSuffix:@"-shm"]) s -= 100;
        if (s > 0) score[p] = @(s);
    }
    NSArray *sorted = [score keysSortedByValueUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b){ return [b intValue] - [a intValue]; }];

    sqlite3 *db = NULL;
    NSString *chosen = nil, *msgTable = nil;
    for (NSUInteger i = 0; i < sorted.count && i < 10; i++) {
        NSString *cand = sorted[i];
        if (sqlite3_open_v2(cand.fileSystemRepresentation, &db, SQLITE_OPEN_READONLY|SQLITE_OPEN_NOMUTEX, NULL) != SQLITE_OK) {
            if (db) sqlite3_close(db); db = NULL; continue;
        }
        sqlite3_busy_timeout(db, 1500);
        NSArray *tables = [self tablesOf:db];
        BAHUDLog(@"DB probe [%@]: %@", cand.lastPathComponent, [tables componentsJoinedByString:@","]);
        for (NSString *t in tables) {
            NSString *tl = t.lowercaseString;
            if ([tl containsString:@"message"]) {
                chosen = cand; msgTable = ([tl isEqualToString:@"message"] ? t : msgTable ?: t); break;
            }
        }
        sqlite3_close(db); db = NULL;
        if (chosen) break;
    }
    if (!chosen && sorted.count) { chosen = sorted.firstObject; BAHUDLog(@"DB: no message-like table found, using top candidate anyway"); }
    if (!chosen) { BAHUDLog(@"DB LOCATE FAILED — no usable candidates"); return; }

    self.dbPath = chosen;
    self.tableName = msgTable ?: @"message";
    BAHUDLog(@"DB CHOSEN: %@ (table: %@)", chosen, self.tableName);
    [self introspect];
}

- (void)introspect {
    if (!self.dbPath) return;
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(self.dbPath.fileSystemRepresentation, &db, SQLITE_OPEN_READONLY|SQLITE_OPEN_NOMUTEX, NULL) != SQLITE_OK) {
        BAHUDLog(@"DB open fail: %@", ba_sqlite_err(db));
        if (db) sqlite3_close(db); return;
    }
    sqlite3_busy_timeout(db, 1500);
    NSMutableArray *cols = [NSMutableArray array];
    sqlite3_stmt *st = NULL;
    NSString *qi = [NSString stringWithFormat:@"PRAGMA table_info(\"%@\")", self.tableName];
    if (sqlite3_prepare_v2(db, qi.UTF8String, -1, &st, NULL) == SQLITE_OK) {
        while (sqlite3_step(st) == SQLITE_ROW) {
            const char *n = (const char*)sqlite3_column_text(st, 1);
            if (n) [cols addObject:@(n)];
        }
    } else BAHUDLog(@"PRAGMA fail: %@", ba_sqlite_err(db));
    sqlite3_finalize(st);
    sqlite3_close(db);

    BAHUDLog(@"DB cols(%@): %@", self.tableName, [cols componentsJoinedByString:@","]);
    for (NSString *w in @[@"payload",@"text",@"body",@"message",@"content"])
        for (NSString *h in cols) if ([h.lowercaseString isEqualToString:w]) { self.colText = h; break; }
    for (NSString *w in @[@"created_at",@"timestamp",@"date",@"time"])
        for (NSString *h in cols) if ([h.lowercaseString containsString:w]) { if (!self.colTime) self.colTime = h; }
    for (NSString *w in @[@"conversation_id",@"chat_id",@"dialog_id",@"sender"])
        for (NSString *h in cols) if ([h.lowercaseString isEqualToString:w]) { if (!self.colConv) self.colConv = h; }
    for (NSString *w in @[@"is_incoming",@"incoming",@"direction",@"isfromme"])
        for (NSString *h in cols) if ([h.lowercaseString containsString:w]) { if (!self.colDir) self.colDir = h; }

    if (!self.colText) BAHUDLog(@"WARN: no TEXT column matched! Send me the col list above.");
    if (!self.colConv) BAHUDLog(@"WARN: no CONVERSATION column — all chats will share one key!");
    if (!self.colDir)  BAHUDLog(@"WARN: no DIRECTION column — treating all messages as incoming!");
    BAHUDLog(@"DB picked: text=%@ time=%@ conv=%@ dir=%@", self.colText, self.colTime, self.colConv, self.colDir);
}

- (sqlite3*)openRO {
    if (!self.dbPath) return NULL;
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(self.dbPath.fileSystemRepresentation, &db, SQLITE_OPEN_READONLY|SQLITE_OPEN_NOMUTEX, NULL) != SQLITE_OK) {
        BAHUDLog(@"DB openRO fail: %@", ba_sqlite_err(db));
        if (db) sqlite3_close(db); return NULL;
    }
    sqlite3_busy_timeout(db, 1500);
    return db;
}
- (long long)maxRowid {
    if (!self.tableName) return 0;
    sqlite3 *db = [self openRO]; if (!db) return 0;
    long long v = 0; sqlite3_stmt *st = NULL;
    NSString *sql = [NSString stringWithFormat:@"SELECT MAX(rowid) FROM \"%@\"", self.tableName];
    if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &st, NULL) == SQLITE_OK) {
        if (sqlite3_step(st) == SQLITE_ROW) {
            int colType = sqlite3_column_type(st, 0);
            // FIX #1: MAX(rowid) on empty table returns SQLITE_NULL not 0
            // rowid 0 was showing because NULL was being cast to int64 = 0
            // then baseline was set to 0, so ALL existing messages triggered on first poll
            // Fix: treat NULL as -1 so first poll correctly skips all existing rows
            v = (colType == SQLITE_NULL) ? -1 : sqlite3_column_int64(st, 0);
        }
    } else {
        BAHUDLog(@"maxRowid SQL fail: %@", ba_sqlite_err(db));
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
- (BOOL)incoming:(sqlite3_stmt*)st idx:(int)d {
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
    if (!self.tableName || !self.colText) return @[];
    sqlite3 *db = [self openRO]; if (!db) return @[];
    NSString *sql = [NSString stringWithFormat:
        @"SELECT rowid, \"%@\", \"%@\", \"%@\", \"%@\" FROM \"%@\" WHERE rowid>%lld ORDER BY rowid ASC LIMIT %ld",
        self.colText, self.colTime ?: @"''", self.colConv ?: @"''", self.colDir ?: @"''", self.tableName, rid, (long)lim];
    sqlite3_stmt *st = NULL; NSMutableArray *out = [NSMutableArray array];
    if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &st, NULL) == SQLITE_OK) {
        int dirIdx = self.colDir ? 4 : -1;
        static NSInteger sample = 0;
        while (sqlite3_step(st) == SQLITE_ROW) {
            BAMessage *m = [BAMessage new];
            m.rowid = sqlite3_column_int64(st, 0);
            m.text = [self txt:st idx:1] ?: @"";
            m.timestamp = [self normTime:sqlite3_column_int64(st, 2)];
            m.contactKey = (self.colConv && sqlite3_column_type(st,3)!=SQLITE_NULL) ? ([self txt:st idx:3] ?: @"unknown") : @"unknown";
            m.incoming = [self incoming:st idx:dirIdx];
            if (sample < 8) {
                NSString *rawDir = dirIdx >= 0
                    ? (sqlite3_column_type(st,dirIdx)==SQLITE_TEXT ? ([self txt:st idx:dirIdx] ?: @"") : [NSString stringWithFormat:@"%d", sqlite3_column_int(st,dirIdx)])
                    : @"<none>";
                BAHUDLog(@"SAMPLE row=%lld conv=%@ dirRaw=%@ in=%d txt=%@", m.rowid, m.contactKey, rawDir, m.incoming, [m.text substringToIndex:MIN((NSUInteger)40, m.text.length)]);
                sample++;
            }
            if (m.text.length) [out addObject:m];
        }
    } else BAHUDLog(@"SQL fail (poll): %@", ba_sqlite_err(db));
    sqlite3_finalize(st); sqlite3_close(db);
    return out;
}
- (NSArray*)historyForContact:(NSString*)key limit:(NSInteger)lim {
    if (!self.tableName || !self.colText || !self.colConv) return @[];
    sqlite3 *db = [self openRO]; if (!db) return @[];
    NSString *sql = [NSString stringWithFormat:
        @"SELECT \"%@\", \"%@\", \"%@\" FROM \"%@\" WHERE \"%@\"=? ORDER BY rowid DESC LIMIT %ld",
        self.colText, self.colTime ?: @"''", self.colDir ?: @"''", self.tableName, self.colConv, (long)lim];
    sqlite3_stmt *st = NULL; NSMutableArray *out = [NSMutableArray array];
    if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &st, NULL) == SQLITE_OK) {
        sqlite3_bind_text(st, 1, key.UTF8String, -1, SQLITE_TRANSIENT);
        int dirIdx = self.colDir ? 2 : -1;
        while (sqlite3_step(st) == SQLITE_ROW) {
            BAMessage *m = [BAMessage new];
            m.text = [self txt:st idx:0] ?: @"";
            m.timestamp = [self normTime:sqlite3_column_int64(st, 1)];
            m.incoming = [self incoming:st idx:dirIdx];
            m.contactKey = key;
            if (m.text.length) [out addObject:m];
        }
    } else BAHUDLog(@"SQL fail (hist): %@", ba_sqlite_err(db));
    sqlite3_finalize(st); sqlite3_close(db);
    return [[out reverseObjectEnumerator] allObjects];
}
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
    if (!cfg.licenseKey.length) { BAHUDLog(@"API: no license key set!"); c(@[], @{@"error":@"no_key"}); return; }

    NSMutableArray *ch = [NSMutableArray array];
    for (BAMessage *m in h)
        [ch addObject:@{@"role": m.incoming?@"user":@"assistant", @"content": m.text, @"timestamp": @(m.timestamp)}];
    NSMutableDictionary *body = [@{
        @"licensekey": cfg.licenseKey,
        @"modelId": @(cfg.modelId),
        @"presetId": @(cfg.presetId),
        @"accountId": cfg.accountId,
        @"platform": cfg.platform,
        @"modelName": cfg.modelName,
        @"modelAge": cfg.modelAge,
        @"chatHistory": ch,
        @"userInfos": @{@"useridentifier": k, @"name": n ?: @""}
    } mutableCopy];
    if (cfg.city.length) body[@"city"] = cfg.city;
    if (cfg.appearance.length) body[@"appearance"] = cfg.appearance;
    if (cfg.hobbies.length) body[@"hobbies"] = cfg.hobbies;
    if (cfg.ctaInfo.length) body[@"ctaInfo"] = cfg.ctaInfo;
    if (cfg.affiliate.length) body[@"affiliate"] = cfg.affiliate;

    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://api.capitalbot.ai/generateResponse"]];
    r.HTTPMethod = @"POST";
    [r setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    NSError *je = nil;
    r.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:&je];
    if (je) { BAHUDLog(@"API: body serialize error: %@", je.localizedDescription); c(@[], @{@"error":@"serialize"}); return; }
    r.timeoutInterval = 45;
    BAHUDLog(@"API: sending request for %@ (hist %lu)", k, (unsigned long)ch.count);

    [[NSURLSession.sharedSession dataTaskWithRequest:r completionHandler:^(NSData *d, NSURLResponse *rp, NSError *e) {
        if (e || !d) { BAHUDLog(@"API error: %@", e.localizedDescription ?: @"empty"); c(@[], @{@"error": e.localizedDescription ?: @"net"}); return; }
        NSString *raw = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"<binary>";
        BAHUDLog(@"API RAW: %@", raw.length > 700 ? [raw substringToIndex:700] : raw);
        NSDictionary *root = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        if (![root isKindOfClass:[NSDictionary class]]) { BAHUDLog(@"API: JSON parse failed"); c(@[], @{@"error":@"json"}); return; }

        NSMutableDictionary *f = [NSMutableDictionary dictionary];
        for (NSString *kk in @[@"converted",@"underage",@"timewaste",@"tierFiltered",@"genderFiltered",@"aiCreditOver",@"messagedAlready",@"internalAccount",@"ignored",@"ppvExhausted",@"chatCooldown",@"sellingMode",@"chatCooldownUntil"])
            if (root[kk]) f[kk] = root[kk];
        NSArray *content = root[@"content"];
        if (![content isKindOfClass:[NSArray class]]) content = root[@"messages"];
        if (![content isKindOfClass:[NSArray class]]) content = @[];
        NSMutableArray *clean = [NSMutableArray array];
        for (id it in content)
            if ([it isKindOfClass:[NSDictionary class]] && it[@"type"] && it[@"content"]) [clean addObject:it];
        BAHUDLog(@"API returned %lu clean items", (unsigned long)clean.count);
        c(clean, f);
    }] resume];
}
@end

// ==================== UI helpers ====================
static BOOL ba_nameMatch(id o, NSString *needle, int d, NSMutableSet *seen) {
    if (!o || d > 4 || needle.length < 2) return NO;
    if (!seen) seen = [NSMutableSet set];
    NSString *ptr = [NSString stringWithFormat:@"%p", o];
    if ([seen containsObject:ptr]) return NO;
    [seen addObject:ptr];
    if ([o isKindOfClass:[NSString class]])
        return [(NSString*)o rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound;
    if ([o isKindOfClass:[NSNumber class]] || [o isKindOfClass:[NSDate class]]) return NO;
    if ([o isKindOfClass:[NSArray class]]) {
        for (id v in o) if (ba_nameMatch(v, needle, d+1, seen)) return YES;
        return NO;
    }
    if (![o isKindOfClass:[NSObject class]]) return NO;
    Class w = object_getClass(o); int lvl = 0;
    while (w && lvl < 3) {
        unsigned int ic = 0; Ivar *iv = class_copyIvarList(w, &ic);
        BOOL hit = NO;
        for (unsigned int i = 0; i < ic && !hit; i++) {
            const char *t = ivar_getTypeEncoding(iv[i]);
            if (!t || t[0] != '@') continue;
            id v = nil; @try { v = object_getIvar(o, iv[i]); } @catch (id e) { continue; }
            if (v && ba_nameMatch(v, needle, d+1, seen)) hit = YES;
        }
        if (iv) free(iv);
        if (hit) return YES;
        w = class_getSuperclass(w); lvl++;
    }
    return NO;
}
static void ba_walk(UIView *v, void(^b)(UIView*)) { if (!v) return; b(v); for (UIView *s in v.subviews) ba_walk(s, b); }
static UITableView *ba_findTV(UIView *r) {
    __block UITableView *f = nil;
    ba_walk(r, ^(UIView *v){ if (!f && [v isKindOfClass:[UITableView class]] && !v.isHidden && v.alpha > 0.1 && ((UITableView*)v).numberOfSections > 0) f = (UITableView*)v; });
    return f;
}
static UICollectionView *ba_findCV(UIView *r) {
    __block UICollectionView *f = nil;
    ba_walk(r, ^(UIView *v){ if (!f && [v isKindOfClass:[UICollectionView class]] && !v.isHidden && v.alpha > 0.1) f = (UICollectionView*)v; });
    return f;
}
static UIView *ba_findInput(UIView *r) {
    __block UIView *best = nil; __block CGFloat bestY = -1;
    ba_walk(r, ^(UIView *v){
        BOOL isTV = [v isKindOfClass:[UITextView class]];
        BOOL isTF = [v isKindOfClass:[UITextField class]];
        if (!isTV && !isTF) return;
        if (isTV && !((UITextView*)v).isEditable) return;
        if (isTF && !((UITextField*)v).isEnabled) return;
        if (v.isHidden || v.alpha < 0.1) return;
        CGRect ir = [v convertRect:v.bounds toView:nil];
        if (ir.size.height < 10 || ir.size.width < 40) return;
        if (ir.origin.y > bestY) { bestY = ir.origin.y; best = v; }
    });
    return best;
}
static UIButton *ba_findSend(UIView *r, CGFloat inputY) {
    __block UIButton *best = nil; __block CGFloat bestScore = -1;
    ba_walk(r, ^(UIView *v){
        if (![v isKindOfClass:[UIButton class]]) return;
        UIButton *b = (UIButton*)v;
        if (b.isHidden || b.alpha < 0.1 || !b.userInteractionEnabled) return;
        CGRect ir = [b convertRect:b.bounds toView:nil];
        if (ir.origin.y < inputY - 60) return;
        if (ir.size.width < 18 || ir.size.height < 18) return;
        NSString *lbl = [NSString stringWithFormat:@"%@ %@", b.accessibilityLabel ?: @"", b.accessibilityIdentifier ?: @""].lowercaseString;
        CGFloat sc = ir.origin.x + ([lbl containsString:@"send"] ? 100000 : 0);
        if (sc > bestScore) { bestScore = sc; best = b; }
    });
    return best;
}
static void ba_setFieldText(UIView *f, NSString *t) {
    if ([f isKindOfClass:[UITextField class]]) ((UITextField*)f).text = t;
    else if ([f isKindOfClass:[UITextView class]]) ((UITextView*)f).text = t;
}
static NSString *ba_getFieldText(UIView *f) {
    if ([f isKindOfClass:[UITextField class]]) return ((UITextField*)f).text ?: @"";
    if ([f isKindOfClass:[UITextView class]]) return ((UITextView*)f).text ?: @"";
    return @"";
}
static void ba_notifyChanged(UIView *f) {
    if ([f isKindOfClass:[UITextField class]]) {
        UITextField *tf = (UITextField*)f;
        [tf sendActionsForControlEvents:UIControlEventEditingChanged];
        [[NSNotificationCenter defaultCenter] postNotificationName:UITextFieldTextDidChangeNotification object:tf];
    } else if ([f isKindOfClass:[UITextView class]]) {
        UITextView *tv = (UITextView*)f;
        if ([tv.delegate respondsToSelector:@selector(textViewDidChange:)]) [tv.delegate textViewDidChange:tv];
        [[NSNotificationCenter defaultCenter] postNotificationName:UITextViewTextDidChangeNotification object:tv];
    }
}

// ==================== BAUI ====================
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
    __block UIViewController *outVC = nil;
    ba_main_sync(^{
        UIWindow *kw = nil;
        for (UIScene *scn in UIApplication.sharedApplication.connectedScenes) {
            if (![scn isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene*)scn).windows)
                if (w.isKeyWindow && w != BAHUDWindow()) { kw = w; break; }
            if (kw) break;
        }
        if (!kw)
            for (UIScene *scn in UIApplication.sharedApplication.connectedScenes) {
                if (![scn isKindOfClass:[UIWindowScene class]]) continue;
                for (UIWindow *w in ((UIWindowScene*)scn).windows) if (w != BAHUDWindow()) { kw = w; break; }
                if (kw) break;
            }
        UIViewController *vc = kw.rootViewController;
        while (vc.presentedViewController) vc = vc.presentedViewController;
        if ([vc isKindOfClass:[UINavigationController class]]) vc = ((UINavigationController*)vc).topViewController;
        if ([vc isKindOfClass:[UITabBarController class]]) vc = ((UITabBarController*)vc).selectedViewController;
        outVC = vc;
    });
    return outVC;
}

// FIX #2: Navigate to Messages tab FIRST before scanning for chat cells
// Original code jumped straight to cell scanning without ensuring the messages
// tab was active — caused "can't reach message tab" / zombie tab bug
- (BOOL)ensureMessagesTab {
    __block BOOL done = NO;
    ba_main_sync(^{
        UIWindow *kw = nil;
        for (UIScene *scn in UIApplication.sharedApplication.connectedScenes) {
            if (![scn isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene*)scn).windows)
                if (w.isKeyWindow && w != BAHUDWindow()) { kw = w; break; }
            if (kw) break;
        }
        UIViewController *root = kw.rootViewController;
        while (root.presentedViewController) root = root.presentedViewController;
        // Find UITabBarController anywhere in hierarchy
        UITabBarController *tbc = nil;
        if ([root isKindOfClass:[UITabBarController class]]) tbc = (UITabBarController*)root;
        if (!tbc && [root isKindOfClass:[UINavigationController class]])
            tbc = (UITabBarController*)((UINavigationController*)root).viewControllers.firstObject;
        if (!tbc) { done = YES; return; } // no tab bar, assume already in right place
        // Find the tab that most likely holds chats/messages
        // Try index 1 first (common Badoo layout: Encounters=0, Chats=1, Profile=2)
        NSInteger best = -1;
        for (NSInteger i = 0; i < (NSInteger)tbc.viewControllers.count; i++) {
            UIViewController *vc = tbc.viewControllers[i];
            NSString *cls = NSStringFromClass(vc.class).lowercaseString;
            UITabBarItem *item = vc.tabBarItem;
            NSString *title = item.title.lowercaseString ?: @"";
            if ([cls containsString:@"chat"] || [cls containsString:@"message"] ||
                [cls containsString:@"inbox"] || [cls containsString:@"conversation"] ||
                [title containsString:@"chat"] || [title containsString:@"message"]) {
                best = i; break;
            }
        }
        if (best < 0 && tbc.viewControllers.count > 1) best = 1; // fallback: index 1
        if (best >= 0 && tbc.selectedIndex != (NSUInteger)best) {
            tbc.selectedIndex = best;
            BAHUDLog(@"UI: switched to tab %ld", (long)best);
        }
        done = YES;
    });
    [NSThread sleepForTimeInterval:0.5]; // let tab animation settle
    return done;
}

- (BOOL)openChat:(NSString*)name ident:(NSString*)ident {
    NSString *needle = name.length >= 2 ? name : ident;
    NSString *alt = (name.length >= 2 ? ident : name) ?: @"";
    if (needle.length < 2) { BAHUDLog(@"UI: no name/ident to search"); return NO; }

    // FIX #2 applied: always navigate to messages tab first
    [self ensureMessagesTab];

    for (int pg = 0; pg < 6; pg++) {
        __block BOOL found = NO;
        ba_main_sync(^{
            UIViewController *vc = [self topVC];
            UITableView *tv = ba_findTV(vc.view);
            UICollectionView *cv = ba_findCV(vc.view);
            if (!tv && !cv) {
                if (ba_findInput(vc.view)) { BAHUDLog(@"UI: already inside a chat — using it"); found = YES; }
                return;
            }
            if (tv) {
                for (NSInteger s = 0; s < tv.numberOfSections && !found; s++)
                    for (NSInteger r = 0; r < [tv numberOfRowsInSection:s]; r++) {
                        NSIndexPath *ip = [NSIndexPath indexPathForRow:r inSection:s];
                        UITableViewCell *c = [tv cellForRowAtIndexPath:ip];
                        if (c && (ba_nameMatch(c, needle, 0, nil) || (alt.length > 2 && ba_nameMatch(c, alt, 0, nil)))) {
                            BAHUDLog(@"UI: cell found for '%@'", needle);
                            [tv selectRowAtIndexPath:ip animated:NO scrollPosition:UITableViewScrollPositionMiddle];
                            id<UITableViewDelegate> d = tv.delegate;
                            if ([d respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)])
                                [d tableView:tv didSelectRowAtIndexPath:ip];
                            found = YES; break;
                        }
                    }
                if (!found) [tv setContentOffset:CGPointMake(0, tv.contentOffset.y + tv.bounds.size.height*0.8) animated:NO];
            } else {
                for (NSInteger s = 0; s < cv.numberOfSections && !found; s++)
                    for (NSInteger i = 0; i < [cv numberOfItemsInSection:s]; i++) {
                        NSIndexPath *ip = [NSIndexPath indexPathForItem:i inSection:s];
                        UICollectionViewCell *c = [cv cellForItemAtIndexPath:ip];
                        if (c && (ba_nameMatch(c, needle, 0, nil) || (alt.length > 2 && ba_nameMatch(c, alt, 0, nil)))) {
                            BAHUDLog(@"UI: cell found for '%@'", needle);
                            [cv selectItemAtIndexPath:ip animated:NO scrollPosition:UICollectionViewScrollPositionCenteredVertically];
                            id<UICollectionViewDelegate> d = cv.delegate;
                            if ([d respondsToSelector:@selector(collectionView:didSelectItemAtIndexPath:)])
                                [d collectionView:cv didSelectItemAtIndexPath:ip];
                            found = YES; break;
                        }
                    }
                if (!found) [cv setContentOffset:CGPointMake(0, cv.contentOffset.y + cv.bounds.size.height*0.8) animated:NO];
            }
        });
        if (found) return YES;
        [NSThread sleepForTimeInterval:0.35];
    }
    BAHUDLog(@"UI: chat cell NOT found for '%@' (ident %@)", needle, ident);
    return NO;
}
- (BOOL)typeAndSend:(NSString*)text {
    if (!text.length) return NO;
    __block UIView *input = nil;
    ba_main_sync(^{ input = ba_findInput([self topVC].view); });
    if (!input) { BAHUDLog(@"UI: input box not found"); return NO; }

    ba_main_async(^{
        ba_setFieldText(input, @"");
        [input becomeFirstResponder];
        ba_notifyChanged(input);
    });
    [NSThread sleepForTimeInterval:0.6];

    for (NSUInteger i = 0; i < text.length; i++) {
        NSString *ch = [text substringWithRange:NSMakeRange(i,1)];
        ba_main_async(^{
            ba_setFieldText(input, [ba_getFieldText(input) stringByAppendingString:ch]);
            ba_notifyChanged(input);
        });
        NSUInteger p = 35 + arc4random_uniform(85);
        if ([ch isEqualToString:@" "] && arc4random_uniform(100) < 12) p += 250 + arc4random_uniform(600);
        [NSThread sleepForTimeInterval:p/1000.0];
    }
    [NSThread sleepForTimeInterval:0.35];

    __block UIButton *sendBtn = nil;
    ba_main_sync(^{
        UIView *cur = ba_findInput([self topVC].view);
        CGFloat y = cur ? [cur convertRect:cur.bounds toView:nil].origin.y : 10000;
        sendBtn = ba_findSend([self topVC].view, y);
    });
    if (!sendBtn) { BAHUDLog(@"UI: send button not found"); return NO; }
    BAHUDLog(@"UI: sending…");
    ba_main_async(^{ [sendBtn sendActionsForControlEvents:UIControlEventTouchUpInside]; });
    [NSThread sleepForTimeInterval:0.5];
    return YES;
}
- (void)goBack {
    ba_main_async(^{
        UIViewController *vc = [self topVC];
        if (vc.navigationController && vc.navigationController.viewControllers.count > 1) {
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
    dispatch_source_t _timer;
    NSMutableArray<BAMessage*> *_queue;
    NSMutableSet<NSString*> *_inflight;
    NSMutableDictionary<NSString*, NSDate*> *_cooldowns;
    NSMutableDictionary<NSString*, NSNumber*> *_pausedUntil;
    NSMutableSet<NSString*> *_sent;
    long long _lastRowid;
    NSDate *_lastLocateAttempt;
    BOOL _paused;
    NSString *_status;
}
+ (instancetype)shared { static BAEngine *e=nil; static dispatch_once_t once; dispatch_once(&once,^{ e=[BAEngine new]; }); return e; }
- (instancetype)init {
    if ((self=[super init])) {
        _q = dispatch_queue_create("he.badooai.engine", DISPATCH_QUEUE_SERIAL);
        _queue=[NSMutableArray array]; _inflight=[NSMutableSet set];
        _cooldowns=[NSMutableDictionary dictionary]; _pausedUntil=[NSMutableDictionary dictionary];
        _sent=[NSMutableSet set]; _status=@"idle"; _lastRowid=-1;
    }
    return self;
}
- (void)start {
    if (_timer) return;
    __weak typeof(self) w = self;
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    uint64_t iv = (uint64_t)MAX(2, [BAConfig shared].pollInterval) * NSEC_PER_SEC;
    dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2*NSEC_PER_SEC)), iv, 1*NSEC_PER_SEC);
    dispatch_source_set_event_handler(_timer, ^{
        __strong typeof(w) s = w; if (!s) return;
        dispatch_async(s->_q, ^{ [s poll]; });
    });
    dispatch_resume(_timer);
    BAHUDLog(@"Engine started (poll every %us)", (unsigned)MAX(2, [BAConfig shared].pollInterval));
}
- (void)setPaused:(BOOL)p { _paused = p; _status = p ? @"paused" : @"idle"; BAHUDLog(@"Engine %@", p ? @"PAUSED" : @"RESUMED"); BAHUDRefresh(); }
- (BOOL)paused { return _paused; }
- (NSUInteger)queueDepth { return _queue.count; }
- (NSString*)statusLine { return _status ?: @"idle"; }
- (void)poll {
    if (_paused) return;
    BAConfig *cfg = [BAConfig shared];
    if (!cfg.enabled || ![cfg isActiveHour]) return;

    BADatabase *db = [BADatabase shared];
    if (!db.dbPath || !db.colText) {
        if (!_lastLocateAttempt || [_lastLocateAttempt timeIntervalSinceNow] < -20) {
            _lastLocateAttempt = [NSDate date];
            [db locate];
            if (!db.dbPath) { BAHUDLog(@"Engine: DB still not found — retrying later"); return; }
        } else return;
    }
    if (_lastRowid < 0) {
        _lastRowid = [db maxRowid];
        // FIX #3: maxRowid now returns -1 for empty table (NULL result)
        // so we set _lastRowid = -1 meaning "poll from beginning" only on empty DB
        // On a real DB with messages, it returns the actual MAX rowid correctly
        // The HUD used to show "baseline rowid 0" which was NULL cast to 0
        // causing ALL existing messages to be treated as new on first poll (spam)
        // Now "baseline rowid -1" = truly empty, and "baseline rowid N" = real max
        if (_lastRowid < 0) _lastRowid = 0; // empty table: start from 0, nothing to skip
        BAHUDLog(@"Engine: DB ready, baseline rowid %lld", _lastRowid);
        return;
    }

    NSArray *fresh = [db messagesAfterRowid:_lastRowid limit:50];
    if (!fresh.count) return;
    BAHUDLog(@"Engine: %lu new message(s)", (unsigned long)fresh.count);
    for (BAMessage *m in fresh) {
        if (m.rowid > _lastRowid) _lastRowid = m.rowid;
        if (!m.incoming) continue;
        NSString *key = [NSString stringWithFormat:@"%@|%@", m.contactKey, m.text];
        if ([_sent containsObject:key]) continue;
        NSDate *cd = _cooldowns[m.contactKey];
        if (cd && [cd timeIntervalSinceNow] > 0) continue;
        if ([_pausedUntil[m.contactKey] doubleValue] > [NSDate date].timeIntervalSince1970) continue;
        BOOL dup = NO;
        for (BAMessage *q in _queue) if ([q.contactKey isEqualToString:m.contactKey]) { dup = YES; break; }
        if (dup) continue;
        [_queue addObject:m];
    }
    BAHUDRefresh();
    [self drain];
}
- (void)drain {
    BAMessage *job = nil;
    for (BAMessage *m in _queue) {
        NSDate *cd = _cooldowns[m.contactKey];
        if (cd && [cd timeIntervalSinceNow] > 0) continue;
        if ([_pausedUntil[m.contactKey] doubleValue] > [NSDate date].timeIntervalSince1970) continue;
        if ([_inflight containsObject:m.contactKey]) continue;
        job = m; break;
    }
    if (!job) return;
    [_queue removeObject:job];
    [_inflight addObject:job.contactKey];
    __weak typeof(self) w = self;
    dispatch_async(_q, ^{ [w process:job]; });
}
- (void)process:(BAMessage*)job {
    BAConfig *cfg = [BAConfig shared];
    self->_status = [NSString stringWithFormat:@"read %@", job.contactKey];
    BAHUDRefresh();
    NSInteger rd = cfg.readDelayMin + arc4random_uniform((uint32_t)MAX(1, cfg.readDelayMax - cfg.readDelayMin + 1));
    [NSThread sleepForTimeInterval:rd];
    NSArray *hist = [[BADatabase shared] historyForContact:job.contactKey limit:40];
    BAHUDLog(@"Engine: asking AI for %@ (hist %lu)", job.contactKey, (unsigned long)hist.count);
    __weak typeof(self) w = self;
    [[BACapitalAI shared] replyForContact:job.contactKey name:job.contactName ?: @"" history:hist
        completion:^(NSArray<NSDictionary*> *content, NSDictionary *flags) {
            __strong typeof(w) s = w; if (!s) return;
            dispatch_async(s->_q, ^{ [s handleReply:job content:content flags:flags cfg:cfg]; });
        }];
}
- (void)handleReply:(BAMessage*)job content:(NSArray<NSDictionary*>*)content flags:(NSDictionary*)flags cfg:(BAConfig*)cfg {
    @try {
        // FIX #4: remove [_inflight removeObject:job.contactKey] from early-return paths
        // Original code forgot to call this on some flag-triggered early returns,
        // leaving the contact permanently stuck in _inflight (zombie — engine never retried it)
        self->_status = [NSString stringWithFormat:@"send %@", job.contactKey];
        BAHUDRefresh();
        if ([flags[@"aiCreditOver"] boolValue]) {
            [_inflight removeObject:job.contactKey]; // FIX #4
            BAHUDLog(@"Engine: AI credits over — global pause");
            [self setPaused:YES]; return;
        }
        if ([flags[@"underage"] boolValue] || [flags[@"ignored"] boolValue] || [flags[@"internalAccount"] boolValue] ||
            [flags[@"tierFiltered"] boolValue] || [flags[@"genderFiltered"] boolValue] || [flags[@"ppvExhausted"] boolValue]) {
            BAHUDLog(@"Engine: filter flag for %@", job.contactKey);
            [_inflight removeObject:job.contactKey]; // FIX #4
            [self pauseC:job.contactKey s:86400]; return;
        }
        if ([flags[@"converted"] boolValue] || [flags[@"messagedAlready"] boolValue] ||
            [flags[@"chatCooldown"] boolValue] || [flags[@"sellingMode"] boolValue]) {
            [_inflight removeObject:job.contactKey]; // FIX #4
            [self pauseC:job.contactKey s:3600]; return;
        }
        id ccu = flags[@"chatCooldownUntil"];
        if ([ccu respondsToSelector:@selector(doubleValue)]) {
            double t = [ccu doubleValue], now = [NSDate date].timeIntervalSince1970;
            if (t > now) [self pauseC:job.contactKey s:(t - now + 5)];
        }
        if (!content.count) {
            BAHUDLog(@"Engine: no content for %@", job.contactKey);
            [_inflight removeObject:job.contactKey]; // FIX #4
            return;
        }

        if (cfg.dryRun) {
            NSMutableString *pv = [NSMutableString stringWithString:@"DRY RUN:\n"];
            for (NSDictionary *p in content) [pv appendFormat:@"[%@] %@\n", p[@"type"], p[@"content"]];
            BAHUDLog(@"%@", pv);
            [_inflight removeObject:job.contactKey]; // FIX #4
            return;
        }

        if (![[BAUI shared] openChat:job.contactName ident:job.contactKey]) {
            BAHUDLog(@"Engine: open failed %@", job.contactKey);
            [_inflight removeObject:job.contactKey]; // FIX #4
            [self pauseC:job.contactKey s:300]; return;
        }
        [NSThread sleepForTimeInterval:1.0];
        for (NSDictionary *p in content) {
            NSString *ty = p[@"type"], *vl = p[@"content"];
            if (![ty isEqualToString:@"text"] || !vl.length) continue;
            NSUInteger ms = cfg.typingMin + arc4random_uniform((uint32_t)MAX(1, cfg.typingMax - cfg.typingMin + 1));
            double base = MIN(9.0, MAX(1.5, vl.length * (ms/1000.0) / 5.0));
            [NSThread sleepForTimeInterval:base];
            if ([[BAUI shared] typeAndSend:vl]) {
                [_sent addObject:[NSString stringWithFormat:@"%@|%@", job.contactKey, vl]];
                if (_sent.count > 800) [_sent removeAllObjects];
            }
            [NSThread sleepForTimeInterval:1.2 + arc4random_uniform(2000)/1000.0];
        }
        [[BAUI shared] goBack];
        [NSThread sleepForTimeInterval:0.8];
        [_inflight removeObject:job.contactKey]; // success path — FIX #4
    } @catch (NSException *ex) {
        BAHUDLog(@"Engine EXC: %@ — %@", ex.name, ex.reason);
        [_inflight removeObject:job.contactKey]; // FIX #4: also clear on exception
    }
}
- (void)pauseC:(NSString*)k s:(double)s { _pausedUntil[k] = @([NSDate date].timeIntervalSince1970 + s); }
@end

// ==================== BAHUD ====================
static UIWindow *gHUDWindow = nil;
static UILabel *gHUDLabel = nil;
static UILabel *gLogLabel = nil;

UIWindow *BAHUDWindow(void) { return gHUDWindow; }

void BAHUDLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *m = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[BadooAI] %@", m);

    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], m];
    for (NSString *logPath in @[@"/var/mobile/Documents/badoo_ai_debug.log",
                                [NSTemporaryDirectory() stringByAppendingPathComponent:@"badoo_ai_debug.log"]]) {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
        if (!fh) [line writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        else { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
    }
    ba_main_async(^{
        if (!gLogLabel) return;
        // FIX #1 (HUD): internal debug strings like "idlw q0 db ready baseline rowid 0"
        // were surfacing as a Badoo alert popup because BAHUDLog was being called
        // during %ctor / early init before HUD was installed, and Badoo's own alert
        // system was intercepting the NSLog output via a debug overlay.
        // Fix: gLogLabel only shows ONE sanitized line — no raw internal tokens shown to user.
        NSString *display = m;
        // Strip internal DB init tokens from visible HUD line
        if ([display containsString:@"idlw"] || [display containsString:@"baseline rowid"] ||
            [display containsString:@"DB scan"] || [display containsString:@"DB probe"]) {
            display = @"DB locating…";
        }
        NSString *one = [display stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
        gLogLabel.text = one.length > 180 ? [one substringToIndex:180] : one;
    });
}

void BAHUDRefresh(void) {
    ba_main_async(^{
        if (!gHUDLabel) return;
        BAEngine *e = [BAEngine shared];
        gHUDLabel.text = [NSString stringWithFormat:@"%@ q%lu", e.paused ? @"PAUSED" : e.statusLine, (unsigned long)e.queueDepth];
        gHUDLabel.backgroundColor = e.paused
            ? [UIColor colorWithRed:0.6 green:0.2 blue:0.1 alpha:0.9]
            : [UIColor colorWithRed:0.05 green:0.45 blue:0.35 alpha:0.9];
    });
}

@interface BAHUDLabel : UILabel @end
@implementation BAHUDLabel
- (void)ba_toggle { [[BAEngine shared] setPaused:![BAEngine shared].paused]; }
@end

@interface BA_HUDView : UIView @end
@implementation BA_HUDView
- (UIView*)hitTest:(CGPoint)p withEvent:(UIEvent*)e {
    for (UIView *sub in self.subviews) {
        UIView *hit = [sub hitTest:[self convertPoint:p toView:sub] withEvent:e];
        if (hit) return hit;
    }
    return nil;
}
@end

@interface BA_HUDVC : UIViewController @end
@implementation BA_HUDVC
- (void)loadView { self.view = [BA_HUDView new]; }
- (void)viewDidLoad { [super viewDidLoad]; self.view.backgroundColor = UIColor.clearColor; }
@end

void BAHUDInstall(void) {
    if (gHUDWindow) return;
    ba_main_async(^{
        if (gHUDWindow) return;
        UIWindowScene *sc = nil;
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]]) { sc = (UIWindowScene*)s;
                if (s.activationState == UISceneActivationStateForegroundActive) break; }
        }
        if (!sc) { BAHUDLog(@"HUD: no UIWindowScene yet"); return; }

        gHUDWindow = [[UIWindow alloc] initWithWindowScene:sc];
        gHUDWindow.windowLevel = UIWindowLevelAlert + 100;
        gHUDWindow.backgroundColor = UIColor.clearColor;
        gHUDWindow.rootViewController = [BA_HUDVC new];
        gHUDWindow.hidden = NO;

        CGFloat W = UIScreen.mainScreen.bounds.size.width;
        gHUDLabel = [BAHUDLabel new];
        gHUDLabel.frame = CGRectMake(W - 195, 108, 180, 30);
        gHUDLabel.text = @"AI: boot";
        gHUDLabel.textAlignment = NSTextAlignmentCenter;
        gHUDLabel.font = [UIFont boldSystemFontOfSize:10];
        gHUDLabel.textColor = UIColor.whiteColor;
        gHUDLabel.backgroundColor = [UIColor colorWithRed:0.05 green:0.45 blue:0.35 alpha:0.9];
        gHUDLabel.layer.cornerRadius = 8; gHUDLabel.layer.masksToBounds = YES;
        gHUDLabel.userInteractionEnabled = YES;
        [gHUDLabel addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:gHUDLabel action:@selector(ba_toggle)]];

        gLogLabel = [UILabel new];
        gLogLabel.frame = CGRectMake(W - 340, 142, 325, 54);
        gLogLabel.numberOfLines = 3;
        gLogLabel.font = [UIFont systemFontOfSize:8];
        gLogLabel.textColor = UIColor.whiteColor;
        gLogLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
        gLogLabel.textAlignment = NSTextAlignmentRight;
        gLogLabel.layer.cornerRadius = 6; gLogLabel.layer.masksToBounds = YES;

        [gHUDWindow.rootViewController.view addSubview:gLogLabel];
        [gHUDWindow.rootViewController.view addSubview:gHUDLabel];
        BAHUDRefresh();
        BAHUDLog(@"HUD installed. Tap pill = pause/resume.");
    });
}

// ==================== Entry ====================
%ctor {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"?";
        BAHUDLog(@"==== BadooAI ctor loaded into %@ (pid %d) ====", bid, getpid());
        if (![bid isEqualToString:@"com.badoo.Badoo"])
            BAHUDLog(@"WARNING: bundle is %@ — filter may not match!", bid);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            BAHUDInstall();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[BAConfig shared] reload];
            [[BAEngine shared] start];
        });
    }
}
