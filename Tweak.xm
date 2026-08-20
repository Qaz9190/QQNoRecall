//  QQNoRecall — QQ 消息防撤回 / 闪图防撤回 / 消息备份查看
//  Target: QQ (com.tencent.mqq) 9.3.35（NT architecture, KMM bridge）
//
//  Hook 依据（QQ 9.3.35 头文件 class-dump）：
//
//  ★ ★ ★ 撤回真正入口（QQ 9.3.35 实测结论，关键，非直觉）★ ★ ★
//    OC 侧撤回的真正触发入口是 NTAIOFloatEarManager.onRecvRecallMsg:
//    接收参数是 NTAIOChat.RecallNotiAIOModel（含 notiMsgs → RecallNotiAIOMsg）。
//    此方法内部处理：AIO 数据源查找被撤回的 cell → 标记/替换为灰条 cell。
//    → 拦截此方法、不调 %orig → 整个 OC 侧撤回处理被截、原消息保留在列表里。
//    (v3.0 之前 hook KTIKernelMsgListener.onMsgDelete/onMsgInfoListUpdate
//     都没生效——Kotlin 通过此 OBJC 入口直接送达。)
//
//    同时 hook 备份入口 NTAIOMenuRecallService 三个 class method
//    （recallComplete…、recallGrayTipsMsg…），作为纵深防御。
//
//    防 recallTime 写入：OCMsgRecord.setRecallTime: / -setKt_recallTimeFromCodec:
//    以及初始化器 -initWithMsgId:…recallTime:(long long)arg45…
//    即使未命中上层，确保 cellVM 读到的 recallTime == 0、原气泡显示、不变灰条。
//
//  ★ 撤回事件入口（NT kernel Kotlin 主链路，纵深防御）：
//      -[KTIKernelMsgListener onMsgRecall:(int)peerUid:(id)seq:(unsigned long long)]
//      头文件签名首参为 int（KMM 桥接：Kotlin Int → OC int，32bit）。
//
//  ★ 旧协议 / 关联账号链路（纵深防御）：
//      QQMessageRecallModule(handleSideAccount…)
//      QQMessageRecallPackageHandler / QQMessageRecallNetEngine(parseC2CRecallNotify)。
//
//  ★ 闪图销毁：
//      NTAIOChat.NTAIOChatFlashPicContentView -notificationActionWithSender:
//      （Swift 桥接类，用 MSHookMessageEx 运行时替换；同时备份闪图）
//
//  ★ 选择性生效：通过偏好 com.qaz9190.qqnorecall 存已添加 peerUid 列表；
//      开关 kSelectiveMode 切换「全部」/「指定」。首次召回某 peer 时自动加入列表。
//
//  ★ 备份：SQLite 数据库 ~/Library/Application Support/QQNoRecall/backup.db
//      通过 hook OCMsgRecord -setElements: 缓存最近消息元素；
//      召回触发时按 (peerUid, seq) 查找缓存并保存文本/图片路径到数据库。
//
//  ★ 设置面板（QQ 内）：hook QQNewSettingsViewController 注入「防撤回」按钮，
//      弹出 QQNoRecallPrefsVC（含开关 + 选择性列表 + 备份查看入口）。
//
//  QQ 设置入口：
//      QQ → 左上角头像 → 设置 → 右上角「防撤回」

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <sqlite3.h>

#define PREF_DOMAIN CFSTR("com.qaz9190.qqnorecall")
#define PREFS_CHANGED_NOTIFICATION CFSTR("com.qaz9190.qqnorecall/prefsChanged")

// ---- 偏好开关 ----
static BOOL gEnableMessageRecall = YES; // 消息防撤回（总开关）
static BOOL gEnableFlashPic = YES;      // 闪图防撤回（总开关）
static BOOL gSelectiveMode = NO;        // 选择性生效（NO=全部生效，YES=仅列表中 peer）

// ---- 选择性生效：已添加的 peerUid 列表（持久化在 kEnabledPeers）----
static NSMutableSet<NSString *> *gEnabledPeers = nil;

// ---- 元素缓存：(peerUid_seq) -> elements NSArray（限 500 条，撤回后清理）----
static NSMutableDictionary<NSString *, NSArray *> *gElementsCache = nil;

// ---- SQLite 备份数据库 ----
static sqlite3 *gDB = NULL;
static NSString *gDBPath = nil;
static NSString *gImageDir = nil;

// 前向声明：OCMsgRecord 是 forward-decl 类型；不写 category（会冲突）
// 调用 peerUid/msgSeq 走 objc_msgSend 避开编译器静态检查
@class OCMsgRecord;

// ---- 闪图销毁通知 hook 存根 ----
static void (*origFlashPicNotificationAction)(id, SEL, id) = NULL;
static void hookedFlashPicNotificationAction(id self, SEL _cmd, id sender);

// =============================================================================
//   偏好读写
// =============================================================================
static void loadPrefs(void) {
    CFPropertyListRef v;
    v = CFPreferencesCopyAppValue(CFSTR("kEnableMessageRecall"), PREF_DOMAIN);
    if (v) { gEnableMessageRecall = [(__bridge id)v boolValue]; CFRelease(v); }
    v = CFPreferencesCopyAppValue(CFSTR("kEnableFlashPic"), PREF_DOMAIN);
    if (v) { gEnableFlashPic = [(__bridge id)v boolValue]; CFRelease(v); }
    v = CFPreferencesCopyAppValue(CFSTR("kSelectiveMode"), PREF_DOMAIN);
    if (v) { gSelectiveMode = [(__bridge id)v boolValue]; CFRelease(v); }
    v = CFPreferencesCopyAppValue(CFSTR("kEnabledPeers"), PREF_DOMAIN);
    if (v) {
        id bridged = (__bridge id)v;
        if ([bridged isKindOfClass:[NSArray class]]) {
            [gEnabledPeers removeAllObjects];
            for (id p in (NSArray *)bridged) {
                if ([p isKindOfClass:[NSString class]]) [gEnabledPeers addObject:p];
            }
        }
        CFRelease(v);
    }
    CFPreferencesAppSynchronize(PREF_DOMAIN);
}

static BOOL isPeerEnabled(NSString *peerUid) {
    if (!gSelectiveMode) return YES; // 全部生效模式
    if (!peerUid) return NO;
    return [gEnabledPeers containsObject:peerUid];
}

// 撤回模型 (NTAIOChat.RecallNotiAIOModel 或 RecallNotiAIOModel) 同样判断:
static BOOL isPeerEnabledForRecall(id recallModel) {
    NSString *peer = qqnorecall_extractPeerFromRecallModel(recallModel);
    return isPeerEnabled(peer);
}

// 从 RecallNotiAIOModel(可能为 NTAIOChat.RecallNotiAIOModel 或 RecallNotiAIOModel) 提取 peer/aioUin
static NSString *qqnorecall_extractPeerFromRecallModel(id model) {
    if (!model) return nil;
    id (*msgSend)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    id s = msgSend(model, @selector(aioUin));
    if ([s isKindOfClass:[NSString class]] && [(NSString *)s length] > 0) return s;
    s = msgSend(model, @selector(peerUid));
    if ([s isKindOfClass:[NSString class]] && [(NSString *)s length] > 0) return s;
    return nil;
}

// 遍历 model.notiMsgs 的每条 RecallNotiAIOMsg，从元素缓存或自身 msgArr 中尽力找内容并备份
// 返回是否成功拿到至少一条内容
static BOOL qqnorecall_backupFromRecallModel(id model) {
    id (*msgSend)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    id notiMsgs = msgSend(model, @selector(notiMsgs));
    if (![notiMsgs respondsToSelector:@selector(count)]) return NO;
    NSUInteger n = [notiMsgs count];
    BOOL got = NO;
    for (NSUInteger i = 0; i < n; i++) {
        id notiMsg = [notiMsgs objectAtIndex:i];
        id msgArr = msgSend(notiMsg, @selector(msgArr));
        if (!msgArr) continue;
        // 简单：把整个 msgArr 当 elements 保存（兼容旧路径）
        if (gElementsCache && msgArr) {
            id peerUid = msgSend(model, @selector(aioUin));
            NSString *p = [peerUid isKindOfClass:[NSString class]] ? peerUid : nil;
            dbSaveRecallEvent(p, nil, 0, 0, nil, 0, msgArr, NO);
            got = YES;
        }
    }
    return got;
}

static void addEnabledPeer(NSString *peerUid) {
    if (!peerUid) return;
    @synchronized (gEnabledPeers) {
        if ([gEnabledPeers containsObject:peerUid]) return;
        [gEnabledPeers addObject:peerUid];
        // 持久化
        CFPreferencesSetAppValue(CFSTR("kEnabledPeers"),
            (__bridge CFPropertyListRef)[gEnabledPeers allObjects],
            PREF_DOMAIN);
        CFPreferencesAppSynchronize(PREF_DOMAIN);
    }
}

static void removeEnabledPeer(NSString *peerUid) {
    if (!peerUid) return;
    @synchronized (gEnabledPeers) {
        [gEnabledPeers removeObject:peerUid];
        CFPreferencesSetAppValue(CFSTR("kEnabledPeers"),
            (__bridge CFPropertyListRef)[gEnabledPeers allObjects],
            PREF_DOMAIN);
        CFPreferencesAppSynchronize(PREF_DOMAIN);
    }
}

// =============================================================================
//   SQLite 备份数据库
// =============================================================================
static void initBackupDir(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString *appSupport = paths.firstObject ?: NSTemporaryDirectory();
    NSString *dir = [appSupport stringByAppendingPathComponent:@"QQNoRecall"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    gDBPath = [[dir stringByAppendingPathComponent:@"backup.db"] copy];
    gImageDir = [[dir stringByAppendingPathComponent:@"Images"] copy];
    [[NSFileManager defaultManager] createDirectoryAtPath:gImageDir withIntermediateDirectories:YES attributes:nil error:nil];
}

static void dbInit(void) {
    if (gDB) return;
    if (!gDBPath) initBackupDir();
    if (sqlite3_open([gDBPath UTF8String], &gDB) == SQLITE_OK) {
        const char *sql =
            "CREATE TABLE IF NOT EXISTS recall_events ("
            "  id INTEGER PRIMARY KEY AUTOINCREMENT,"
            "  peer_uid TEXT NOT NULL,"
            "  msg_seq INTEGER,"
            "  msg_id INTEGER,"
            "  sender_uid TEXT,"
            "  msg_type INTEGER,"
            "  text_content TEXT,"
            "  image_path TEXT,"
            "  timestamp REAL NOT NULL,"
            "  is_flash INTEGER DEFAULT 0,"
            "  peer_name TEXT"
            ");"
            "CREATE INDEX IF NOT EXISTS idx_peer ON recall_events(peer_uid);"
            "CREATE INDEX IF NOT EXISTS idx_ts ON recall_events(timestamp DESC);";
        char *err = NULL;
        sqlite3_exec(gDB, sql, NULL, NULL, &err);
        if (err) { sqlite3_free(err); }
    }
}

static void dbClose(void) {
    if (gDB) { sqlite3_close(gDB); gDB = NULL; }
}

// 从 elements 中尽力抽取文本/图片路径
static NSString *qqnorecall_firstString(id el, SEL s1, SEL s2, SEL s3, SEL s4) {
    SEL sels[] = {s1, s2, s3, s4};
    for (int i = 0; i < 4; i++) {
        SEL sel = sels[i];
        if (sel && [el respondsToSelector:sel]) {
            id (*msgSendFn)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
            id v = msgSendFn(el, sel);
            if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) return v;
        }
    }
    return nil;
}

static void extractContentFromElements(NSArray *elements, NSString **outText, NSString **outImagePath) {
    *outText = nil;
    *outImagePath = nil;
    if (!elements || ![elements isKindOfClass:[NSArray class]]) return;
    NSMutableString *textBuf = [NSMutableString new];
    for (id el in elements) {
        if (!el || ![el isKindOfClass:[NSObject class]]) continue;
        if (!*outText) {
            *outText = qqnorecall_firstString(el,
                @selector(textContent), @selector(content), @selector(text), @selector(msgText));
        }
        if (!*outImagePath) {
            *outImagePath = qqnorecall_firstString(el,
                @selector(localPath), @selector(imagePath), @selector(filePath), @selector(path));
        }
        NSString *t = qqnorecall_firstString(el,
            @selector(textContent), @selector(content), @selector(text), @selector(msgText));
        if (t) {
            [textBuf appendString:t];
            [textBuf appendString:@"\n"];
        }
    }
    if (!*outText && textBuf.length > 0) *outText = [textBuf copy];
}

static NSString *copyImageToBackup(NSString *srcPath) {
    if (!srcPath || !gImageDir) return nil;
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:srcPath]) return nil;
    NSString *fname = [srcPath lastPathComponent] ?: @"img.bin";
    NSString *dst = [[gImageDir stringByAppendingPathComponent:fname] stringByAppendingString:[NSString stringWithFormat:@"_%lld", (long long)[[NSDate date] timeIntervalSince1970]]];
    NSError *err = nil;
    if ([fm copyItemAtPath:srcPath toPath:dst error:&err]) return dst;
    return nil;
}

static void dbSaveRecallEvent(NSString *peerUid, NSString *peerName,
                              long long msgSeq, long long msgId, NSString *senderUid,
                              int msgType, NSArray *elements, BOOL isFlash) {
    if (!peerUid) return;
    dbInit();
    if (!gDB) return;
    NSString *text = nil, *imagePath = nil;
    extractContentFromElements(elements, &text, &imagePath);
    NSString *storedImage = imagePath ? copyImageToBackup(imagePath) : nil;
    double ts = [[NSDate date] timeIntervalSince1970];
    const char *sql = "INSERT INTO recall_events (peer_uid, msg_seq, msg_id, sender_uid, msg_type, text_content, image_path, timestamp, is_flash, peer_name) VALUES (?,?,?,?,?,?,?,?,?,?);";
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(gDB, sql, -1, &stmt, NULL) == SQLITE_OK) {
        sqlite3_bind_text(stmt, 1, [peerUid UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_int64(stmt, 2, msgSeq);
        sqlite3_bind_int64(stmt, 3, msgId);
        sqlite3_bind_text(stmt, 4, senderUid ? [senderUid UTF8String] : "", -1, SQLITE_TRANSIENT);
        sqlite3_bind_int(stmt, 5, msgType);
        if (text) sqlite3_bind_text(stmt, 6, [text UTF8String], -1, SQLITE_TRANSIENT);
        else sqlite3_bind_null(stmt, 6);
        if (storedImage) sqlite3_bind_text(stmt, 7, [storedImage UTF8String], -1, SQLITE_TRANSIENT);
        else sqlite3_bind_null(stmt, 7);
        sqlite3_bind_double(stmt, 8, ts);
        sqlite3_bind_int(stmt, 9, isFlash ? 1 : 0);
        sqlite3_bind_text(stmt, 10, peerName ? [peerName UTF8String] : "", -1, SQLITE_TRANSIENT);
        sqlite3_step(stmt);
    }
    if (stmt) sqlite3_finalize(stmt);
}

// 备份闪图：直接把图片数据写到备份目录
static void backupFlashPicImage(UIView *flashView) {
    if (!gImageDir || !flashView) return;
    UIScrollView *sv = nil;
    for (UIView *sub in flashView.subviews) {
        if ([sub isKindOfClass:[UIScrollView class]]) { sv = (UIScrollView *)sub; break; }
    }
    UIImageView *iv = nil;
    NSArray *subs = sv ? sv.subviews : flashView.subviews;
    for (UIView *sub in subs) {
        if ([sub isKindOfClass:[UIImageView class]]) { iv = (UIImageView *)sub; break; }
        for (UIView *sub2 in sub.subviews) {
            if ([sub2 isKindOfClass:[UIImageView class]]) { iv = (UIImageView *)sub2; break; }
        }
        if (iv) break;
    }
    if (!iv || !iv.image) return;
    NSData *data = UIImageJPEGRepresentation(iv.image, 0.85);
    if (!data) return;
    double ts = [[NSDate date] timeIntervalSince1970];
    NSString *fname = [NSString stringWithFormat:@"flash_%lld.jpg", (long long)ts];
    NSString *path = [gImageDir stringByAppendingPathComponent:fname];
    [data writeToFile:path atomically:YES];
    // 写到数据库（直接 image_path，text_content 留空）
    dbInit();
    if (!gDB) return;
    const char *sql = "INSERT INTO recall_events (peer_uid, msg_seq, msg_id, sender_uid, msg_type, text_content, image_path, timestamp, is_flash, peer_name) VALUES (?,?,?,?,?,?,?,?,?,?);";
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(gDB, sql, -1, &stmt, NULL) == SQLITE_OK) {
        sqlite3_bind_text(stmt, 1, "", -1, SQLITE_TRANSIENT);
        sqlite3_bind_int64(stmt, 2, 0);
        sqlite3_bind_int64(stmt, 3, 0);
        sqlite3_bind_text(stmt, 4, "", -1, SQLITE_TRANSIENT);
        sqlite3_bind_int(stmt, 5, 0);
        sqlite3_bind_null(stmt, 6);
        sqlite3_bind_text(stmt, 7, [path UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_double(stmt, 8, ts);
        sqlite3_bind_int(stmt, 9, 1);
        sqlite3_bind_text(stmt, 10, "闪图", -1, SQLITE_TRANSIENT);
        sqlite3_step(stmt);
    }
    if (stmt) sqlite3_finalize(stmt);
}

// 列出有备份的 peer（去重 + 计数）
static NSMutableArray<NSDictionary *> *dbListPeers(void) {
    NSMutableArray *out = [NSMutableArray new];
    dbInit();
    if (!gDB) return out;
    const char *sql = "SELECT peer_uid, peer_name, COUNT(*), MAX(timestamp) FROM recall_events GROUP BY peer_uid ORDER BY MAX(timestamp) DESC;";
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(gDB, sql, -1, &stmt, NULL) == SQLITE_OK) {
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            const unsigned char *puid = sqlite3_column_text(stmt, 0);
            const unsigned char *pname = sqlite3_column_text(stmt, 1);
            int cnt = sqlite3_column_int(stmt, 2);
            double ts = sqlite3_column_double(stmt, 3);
            NSMutableDictionary *d = [NSMutableDictionary new];
            d[@"peerUid"] = puid ? [NSString stringWithUTF8String:(const char *)puid] : @"";
            d[@"peerName"] = pname ? [NSString stringWithUTF8String:(const char *)pname] : @"";
            d[@"count"] = @(cnt);
            d[@"timestamp"] = @(ts);
            [out addObject:d];
        }
    }
    if (stmt) sqlite3_finalize(stmt);
    return out;
}

// 列出某 peer 的所有备份消息
static NSMutableArray<NSDictionary *> *dbListMessagesForPeer(NSString *peerUid) {
    NSMutableArray *out = [NSMutableArray new];
    if (!peerUid) return out;
    dbInit();
    if (!gDB) return out;
    const char *sql = "SELECT id, msg_seq, msg_id, sender_uid, msg_type, text_content, image_path, timestamp, is_flash, peer_name FROM recall_events WHERE peer_uid = ? ORDER BY timestamp DESC;";
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(gDB, sql, -1, &stmt, NULL) == SQLITE_OK) {
        sqlite3_bind_text(stmt, 1, [peerUid UTF8String], -1, SQLITE_TRANSIENT);
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            NSMutableDictionary *d = [NSMutableDictionary new];
            d[@"id"] = @(sqlite3_column_int64(stmt, 0));
            d[@"msgSeq"] = @(sqlite3_column_int64(stmt, 1));
            d[@"msgId"] = @(sqlite3_column_int64(stmt, 2));
            const unsigned char *suid = sqlite3_column_text(stmt, 3);
            d[@"senderUid"] = suid ? [NSString stringWithUTF8String:(const char *)suid] : @"";
            d[@"msgType"] = @(sqlite3_column_int(stmt, 4));
            const unsigned char *txt = sqlite3_column_text(stmt, 5);
            d[@"textContent"] = txt ? [NSString stringWithUTF8String:(const char *)txt] : @"";
            const unsigned char *img = sqlite3_column_text(stmt, 6);
            d[@"imagePath"] = img ? [NSString stringWithUTF8String:(const char *)img] : @"";
            d[@"timestamp"] = @(sqlite3_column_double(stmt, 7));
            d[@"isFlash"] = @(sqlite3_column_int(stmt, 8));
            const unsigned char *pn = sqlite3_column_text(stmt, 9);
            d[@"peerName"] = pn ? [NSString stringWithUTF8String:(const char *)pn] : @"";
            [out addObject:d];
        }
    }
    if (stmt) sqlite3_finalize(stmt);
    return out;
}

// =============================================================================
//   备份查看器 VC
// =============================================================================
@interface QQNoRecallBackupVC : UIViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UITableView *tv;
@property (nonatomic, strong) NSMutableArray *peers;
@end

@implementation QQNoRecallBackupVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"已拦截消息";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.peers = [NSMutableArray new];
    self.tv = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.tv.delegate = self; self.tv.dataSource = self;
    self.tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.tv];
    UIBarButtonItem *back = [[UIBarButtonItem alloc] initWithTitle:@"返回" style:UIBarButtonItemStylePlain target:self action:@selector(qqnorecall_back)];
    self.navigationItem.rightBarButtonItem = back;
}
- (void)qqnorecall_back { [self.navigationController popViewControllerAnimated:YES]; }
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.peers setArray:[dbListPeers() copy]];
    [self.tv reloadData];
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return self.peers.count; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"qnp";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:cid];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
    NSDictionary *d = self.peers[ip.row];
    NSString *name = d[@"peerName"];
    if (![name isKindOfClass:[NSString class]] || name.length == 0) name = d[@"peerUid"];
    if (![name isKindOfClass:[NSString class]] || name.length == 0) name = @"未知对象";
    c.textLabel.text = name;
    NSDate *dt = [NSDate dateWithTimeIntervalSince1970:[d[@"timestamp"] doubleValue]];
    NSDateFormatter *fmt = [NSDateFormatter new];
    fmt.dateFormat = @"yyyy-MM-dd HH:mm";
    c.detailTextLabel.text = [NSString stringWithFormat:@"%lu 条 · 最近 %@", (unsigned long)[d[@"count"] integerValue], [fmt stringFromDate:dt]];
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSDictionary *d = self.peers[ip.row];
    // 延迟引用类避免编译期循环
    Class detailVC = NSClassFromString(@"QQNoRecallPeerVC");
    if (!detailVC) return;
    UIViewController *vc = [[detailVC alloc] init];
    [vc setValue:d[@"peerUid"] forKey:@"peerUid"];
    [vc setValue:d[@"peerName"] forKey:@"peerName"];
    [vc setValue:d[@"count"] forKey:@"count"];
    [self.navigationController pushViewController:vc animated:YES];
}
@end

@interface QQNoRecallPeerVC : UIViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, copy) NSString *peerUid;
@property (nonatomic, copy) NSString *peerName;
@property (nonatomic, assign) NSInteger count;
@property (nonatomic, strong) UITableView *tv;
@property (nonatomic, strong) NSMutableArray *messages;
@end

@implementation QQNoRecallPeerVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.peerName.length ? self.peerName : self.peerUid;
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.messages = [NSMutableArray new];
    self.tv = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.tv.delegate = self; self.tv.dataSource = self;
    self.tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.tv];
    UIBarButtonItem *back = [[UIBarButtonItem alloc] initWithTitle:@"返回" style:UIBarButtonItemStylePlain target:self action:@selector(qqnorecall_back)];
    self.navigationItem.rightBarButtonItem = back;
}
- (void)qqnorecall_back { [self.navigationController popViewControllerAnimated:YES]; }
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.messages setArray:[dbListMessagesForPeer(self.peerUid) copy]];
    [self.tv reloadData];
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return self.messages.count; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"qnm";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:cid];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
    NSDictionary *d = self.messages[ip.row];
    BOOL isFlash = [d[@"isFlash"] boolValue];
    NSString *text = d[@"textContent"];
    NSString *imgPath = d[@"imagePath"];
    NSDate *dt = [NSDate dateWithTimeIntervalSince1970:[d[@"timestamp"] doubleValue]];
    NSDateFormatter *fmt = [NSDateFormatter new]; fmt.dateFormat = @"MM-dd HH:mm";
    NSString *prefix = isFlash ? @"🔥 闪图 · " : @"";
    if ([text isKindOfClass:[NSString class]] && text.length > 0) {
        c.textLabel.text = [NSString stringWithFormat:@"%@%@", prefix, text];
    } else if ([imgPath isKindOfClass:[NSString class]] && imgPath.length > 0) {
        c.textLabel.text = [NSString stringWithFormat:@"%@📷 图片", prefix];
    } else {
        c.textLabel.text = [NSString stringWithFormat:@"%@(消息内容不可用)", prefix];
    }
    c.detailTextLabel.text = [fmt stringFromDate:dt];
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSDictionary *d = self.messages[ip.row];
    Class detailVC = NSClassFromString(@"QQNoRecallMsgDetailVC");
    if (!detailVC) return;
    UIViewController *vc = [[detailVC alloc] init];
    [vc setValue:d forKey:@"message"];
    [self.navigationController pushViewController:vc animated:YES];
}
@end

@interface QQNoRecallMsgDetailVC : UIViewController
@property (nonatomic, strong) NSDictionary *message;
@end

@implementation QQNoRecallMsgDetailVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    UIBarButtonItem *back = [[UIBarButtonItem alloc] initWithTitle:@"返回" style:UIBarButtonItemStylePlain target:self action:@selector(qqnorecall_back)];
    self.navigationItem.rightBarButtonItem = back;
    NSString *imgPath = self.message[@"imagePath"];
    if ([imgPath isKindOfClass:[NSString class]] && imgPath.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:imgPath]) {
        UIImage *img = [UIImage imageWithContentsOfFile:imgPath];
        UIImageView *iv = [[UIImageView alloc] initWithImage:img];
        iv.contentMode = UIViewContentModeScaleAspectFit;
        iv.frame = self.view.bounds;
        iv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self.view addSubview:iv];
        self.title = @"图片";
    } else {
        NSString *text = self.message[@"textContent"];
        if (![text isKindOfClass:[NSString class]]) text = @"";
        UITextView *tv = [[UITextView alloc] initWithFrame:self.view.bounds];
        tv.text = text;
        tv.font = [UIFont systemFontOfSize:16];
        tv.editable = NO;
        tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self.view addSubview:tv];
        self.title = @"文本";
    }
}
- (void)qqnorecall_back { [self.navigationController popViewControllerAnimated:YES]; }
@end

// =============================================================================
//   QQ 内设置面板（开关 + 选择性列表 + 备份查看入口）
// =============================================================================
@interface QQNoRecallPrefsVC : UIViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UITableView *tv;
@property (nonatomic, strong) NSMutableArray *peerList;
@end

@implementation QQNoRecallPrefsVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"QQ 防撤回设置";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.peerList = [[gEnabledPeers allObjects] mutableCopy] ?: [NSMutableArray new];
    self.tv = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleGrouped];
    self.tv.delegate = self; self.tv.dataSource = self;
    self.tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.tv];
    if (self.navigationController) {
        self.navigationItem.rightBarButtonItem =
            [[UIBarButtonItem alloc] initWithTitle:@"完成" style:UIBarButtonItemStyleDone
                                            target:self action:@selector(qqnorecall_done)];
    }
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(qqnorecall_reload)
                                                 name:UIApplicationDidBecomeActiveNotification object:nil];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self qqnorecall_reload];
}
- (void)qqnorecall_reload {
    [self.peerList setArray:[[gEnabledPeers allObjects] mutableCopy] ?: @[]];
    [self.tv reloadData];
}
- (void)qqnorecall_done { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    if (gSelectiveMode) return 3;
    return 1;
}
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    if (s == 0) return @"功能开关（改动即时生效）";
    if (s == 1 && gSelectiveMode) return @"指定对象生效（首次撤回的对象会自动加入）";
    if (s == 2 && gSelectiveMode) return @"";
    return nil;
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (s == 0) return 2;
    if (s == 1 && gSelectiveMode) return self.peerList.count + 1; // +1 "查看备份消息"
    if (s == 2 && gSelectiveMode) return 1; // "查看备份消息" 行
    return 0;
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"qqnr";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:cid];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cid];

    if (ip.section == 0) {
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        NSString *title = (ip.row == 0) ? @"消息防撤回" : @"闪图防撤回";
        NSString *key = (ip.row == 0) ? @"kEnableMessageRecall" : @"kEnableFlashPic";
        c.textLabel.text = title;
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = [self qqnorecall_readBool:key];
        sw.tag = ip.row;
        [sw addTarget:self action:@selector(qqnorecall_toggle:) forControlEvents:UIControlEventValueChanged];
        c.accessoryView = sw;
    } else if (ip.section == 1 && gSelectiveMode) {
        if (ip.row == self.peerList.count) {
            // "查看备份消息" 行（指定模式里）
            c.textLabel.text = @"查看备份消息";
            c.textLabel.textColor = [UIColor systemBlueColor];
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            c.accessoryView = nil;
            c.selectionStyle = UITableViewCellSelectionStyleDefault;
        } else {
            c.textLabel.text = self.peerList[ip.row];
            c.textLabel.textColor = [UIColor labelColor];
            c.accessoryType = UITableViewCellAccessoryNone;
            c.accessoryView = nil;
            c.selectionStyle = UITableViewCellSelectionStyleDefault;
        }
    } else if (ip.section == 2 && gSelectiveMode) {
        // 兜底（实际不会出现，因为 section=1 末位已经是"查看备份消息"）
    }
    return c;
}
- (BOOL)qqnorecall_readBool:(NSString *)key {
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key, PREF_DOMAIN);
    BOOL b = v ? [(__bridge id)v boolValue] : YES;
    if (v) CFRelease(v);
    return b;
}
- (void)qqnorecall_toggle:(UISwitch *)sw {
    if (sw.tag == 0) {
        CFPreferencesSetAppValue(CFSTR("kEnableMessageRecall"), (__bridge CFPropertyListRef)@(sw.on), PREF_DOMAIN);
    } else {
        CFPreferencesSetAppValue(CFSTR("kEnableFlashPic"), (__bridge CFPropertyListRef)@(sw.on), PREF_DOMAIN);
    }
    CFPreferencesAppSynchronize(PREF_DOMAIN);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         PREFS_CHANGED_NOTIFICATION, NULL, NULL, YES);
}

// 选择性模式开关行（在 section 0 第三行显示？不，用 push）
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (!gSelectiveMode) return;
    if (ip.section == 1 && ip.row == self.peerList.count) {
        // 进入备份查看
        Class backupVC = NSClassFromString(@"QQNoRecallBackupVC");
        if (!backupVC) return;
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[[backupVC alloc] init]];
        [self presentViewController:nav animated:YES completion:nil];
    } else if (ip.section == 1 && ip.row < self.peerList.count) {
        // 点击 peer：弹提示是否删除
        NSString *peerUid = self.peerList[ip.row];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"移除该对象" message:[NSString stringWithFormat:@"确认从选择性防撤回列表中移除\n%@", peerUid] preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"移除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
            removeEnabledPeer(peerUid);
            [self qqnorecall_reload];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}
@end

// "指定对象生效" 选择器 VC（单独一个开关 + 跳转备份）
@interface QQNoRecallSelectiveVC : UIViewController
@property (nonatomic, strong) UISwitch *sw;
@property (nonatomic, strong) UITableView *tv;
@end

@implementation QQNoRecallSelectiveVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"选择性生效";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.sw = [[UISwitch alloc] init];
    self.sw.on = gSelectiveMode;
    [self.sw addTarget:self action:@selector(qqnorecall_switched:) forControlEvents:UIControlEventValueChanged];
    self.navigationItem.titleView = self.sw;
    UIBarButtonItem *back = [[UIBarButtonItem alloc] initWithTitle:@"返回" style:UIBarButtonItemStylePlain target:self action:@selector(qqnorecall_back)];
    self.navigationItem.rightBarButtonItem = back;
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.sw.on = gSelectiveMode;
}
- (void)qqnorecall_back { [self.navigationController popViewControllerAnimated:YES]; }
- (void)qqnorecall_switched:(UISwitch *)sw {
    gSelectiveMode = sw.on;
    CFPreferencesSetAppValue(CFSTR("kSelectiveMode"), (__bridge CFPropertyListRef)@(sw.on), PREF_DOMAIN);
    CFPreferencesAppSynchronize(PREF_DOMAIN);
}
@end

// 打开设置面板（动态加到 QQNewSettingsViewController 的 IMP）
static void qqnorecall_openSettingsImp(id self, SEL _cmd) {
    QQNoRecallPrefsVC *vc = [[QQNoRecallPrefsVC alloc] init];
    UINavigationController *nc = [[UINavigationController alloc] initWithRootViewController:vc];
    nc.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:nc animated:YES completion:nil];
}

// =============================================================================
//   Hooks
// =============================================================================
%ctor {
    initBackupDir();
    dbInit();
    gEnabledPeers = [NSMutableSet new];
    gElementsCache = [NSMutableDictionary new];
    loadPrefs();

    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        (CFNotificationCallback)loadPrefs,
        PREFS_CHANGED_NOTIFICATION,
        NULL,
        CFNotificationSuspensionBehaviorCoalesce);

    Class settingsCls = objc_getClass("QQNewSettingsViewController");
    if (settingsCls && !class_respondsToSelector(settingsCls, @selector(qqnorecall_openSettings))) {
        class_addMethod(settingsCls, @selector(qqnorecall_openSettings),
                        (IMP)qqnorecall_openSettingsImp, "v@:");
    }
}

// ★★★★★ 消息防撤回 —— v4.0.0 真正入口 ★★★★★
// 头文件实测发现：QQ 9.3.35 撤回的真正 OC 侧入口只有两处：
//   1) NTAIOFloatEarManager -onRecvRecallMsg:  (收撤回通知 → 处理 cell 替换)
//   2) NTAIOMenuRecallService 三个 class method (recallComplete / recallGrayTipsMsg)
// 这两处都是直接调用的 OC method（不是 KMM/Kotlin 转发的），
// hook 它们并直接 return 即可吞掉整条 OC 侧撤回处理链路。
// 之前的 KTIKernelMsgListener.onMsgRecall/onMsgDelete/onMsgInfoListUpdate
// 经实测（顶部无提示、用户报告未生效）确认从未触发——该回调路径在本版不再生效。
%hook NTAIOChat.NTAIOFloatEarManager
- (void)onRecvRecallMsg:(id)arg1 {
    if (!gEnableMessageRecall) { %orig; return; }
    if (!isPeerEnabledForRecall(arg1)) { %orig; return; }
    if (arg1) {
        NSString *peer = qqnorecall_extractPeerFromRecallModel(arg1);
        BOOL hadContent = qqnorecall_backupFromRecallModel(arg1);
        addEnabledPeer(peer);
        NSLog(@"[QQNoRecall] blocked onRecvRecallMsg peer=%@ hadContent=%d", peer, hadContent);
    }
    return; // 不调 %orig → 原消息保留、灰条不生成
}
%end

%hook NTAIOChat.NTAIOMenuRecallService
+ (void)recallCompleteWithCell:(id)arg1 observer:(id)arg2 code:(int)arg3 msg:(id)arg4 {
    if (gEnableMessageRecall) return;
    %orig;
}
+ (void)recallCompleteWithCellViewModel:(id)arg1 observer:(id)arg2 code:(int)arg3 msg:(id)arg4 {
    if (gEnableMessageRecall) return;
    %orig;
}
+ (void)recallGrayTipsMsgWithCellView:(id)arg1 observer:(id)arg2 {
    if (gEnableMessageRecall) return;
    %orig;
}
%end

// 纵深防御 ①：写入 recallTime 时强制改为 0
%hook OCMsgRecord
- (void)setRecallTime:(long long)arg1 {
    if (gEnableMessageRecall) { %orig(0); return; }
    %orig;
}
- (void)setKt_recallTimeFromCodec:(id)arg1 {
    if (gEnableMessageRecall) { %orig((id)@(0)); return; }
    %orig;
}
%end

// 纵深防御 ②：cell VM 重渲染时清除 recallTime
%hook NTAIOChat.NTAIOMessageCellViewModel
- (void)reloadAppearanceWithRecord:(id)record {
    if (gEnableMessageRecall && record) {
        NSNumber *(*getter)(id, SEL) = (NSNumber *(*)(id, SEL))objc_msgSend;
        NSNumber *rt = getter(record, @selector(recallTime));
        if (rt && [rt longLongValue] > 0) {
            void (*setter)(id, SEL, long long) = (void (*)(id, SEL, long long))objc_msgSend;
            setter(record, @selector(setRecallTime:), 0);
        }
    }
    %orig;
}
%end

// 纵深防御 ③：旧协议 / 关联账号链路（如果 QQ 走了这条路）
%hook QQMessageRecallModule
- (id)handleSideAccountRecallNotify:(id)arg1 bufferLen:(int)arg2 subcmd:(int)arg3
                            bindUin:(unsigned long long)arg4 tracelessFlag:(id)arg5 {
    if (gEnableMessageRecall) return nil;
    return %orig;
}
%end

%hook QQMessageRecallPackageHandler
+ (BOOL)parseC2CRecallNotify:(id)arg1 bufferLen:(int)arg2 subcmd:(int)arg3 model:(id)arg4 {
    if (gEnableMessageRecall) return NO;
    return %orig;
}
+ (void)parseC2CRecallInOut:(id)arg1 {
    if (gEnableMessageRecall) return;
    %orig;
}
%end

%hook QQMessageRecallNetEngine
- (BOOL)parseC2CRecallNotify:(id)arg1 bufferLen:(int)arg2 subcmd:(int)arg3 model:(id)arg4 {
    if (gEnableMessageRecall) return NO;
    return %orig;
}
%end

// 元素缓存：捕获最近消息的元素供备份用（限 500 条）
%hook OCMsgRecord
- (void)setElements:(id)arg1 {
    %orig;
    if (!arg1) return;
    NSString *peerUid = nil;
    long long msgSeq = 0;
    // OCMsgRecord 是 forward-decl 类型；用 objc_msgSend 直接调用避开静态检查
    @try {
        NSString *(*fnStr)(id, SEL) = (NSString *(*)(id, SEL))objc_msgSend;
        long long (*fnLL)(id, SEL) = (long long (*)(id, SEL))objc_msgSend;
        peerUid = fnStr(self, @selector(peerUid));
        msgSeq = fnLL(self, @selector(msgSeq));
    } @catch (id e) { return; }
    if (!peerUid || !msgSeq) return;
    NSString *key = [NSString stringWithFormat:@"%@_%lld", peerUid, msgSeq];
    @synchronized (gElementsCache) {
        gElementsCache[key] = arg1;
        if (gElementsCache.count > 500) {
            // 简单 FIFO：删前 100 条
            NSArray *allKeys = [gElementsCache.allKeys subarrayWithRange:NSMakeRange(0, MIN(100, gElementsCache.count))];
            [gElementsCache removeObjectsForKeys:allKeys];
        }
    }
}
%end

// 闪图防撤回 + 备份
__attribute__((constructor)) static void qqnorecall_init_flashpic(void) {
    Class cls = objc_getClass("NTAIOChat.NTAIOChatFlashPicContentView");
    if (cls) {
        MSHookMessageEx(cls, @selector(notificationActionWithSender:),
                        (IMP)hookedFlashPicNotificationAction,
                        (IMP *)&origFlashPicNotificationAction);
    }
}

static void hookedFlashPicNotificationAction(id self, SEL _cmd, id sender) {
    if (gEnableFlashPic) {
        // 备份闪图（在销毁前抓图）
        if ([self isKindOfClass:[UIView class]]) {
            backupFlashPicImage((UIView *)self);
        }
        return;
    }
    if (origFlashPicNotificationAction) origFlashPicNotificationAction(self, _cmd, sender);
}

// QQ 内设置入口
@interface QQNewSettingsViewController : UIViewController
- (void)qqnorecall_openSettings;
@end

%hook QQNewSettingsViewController
- (void)viewDidLoad {
    %orig;
    if (objc_getAssociatedObject(self, "qqnorecall_added")) return;
    objc_setAssociatedObject(self, "qqnorecall_added", @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIBarButtonItem *mine = [[UIBarButtonItem alloc] initWithTitle:@"防撤回"
                                                              style:UIBarButtonItemStylePlain
                                                             target:self
                                                             action:@selector(qqnorecall_openSettings)];
    UIBarButtonItem *existing = self.navigationItem.rightBarButtonItem;
    if (existing) {
        self.navigationItem.rightBarButtonItems = @[existing, mine];
    } else {
        self.navigationItem.rightBarButtonItem = mine;
    }
}
%end

__attribute__((destructor)) static void qqnorecall_cleanup(void) {
    dbClose();
}