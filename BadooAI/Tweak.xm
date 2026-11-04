#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <stdarg.h>

static UIWindow *gReconWindow = nil;
static UILabel *gReconLabel = nil;

void RCLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[BadooRecon] %@", msg);
    
    NSString *dir = @"/var/mobile/Documents/BadooRecon";
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [dir stringByAppendingPathComponent:@"session.log"];
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], msg];
    
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    else { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
}

void RCDumpClassMap(void) {
    NSString *dir = @"/var/mobile/Documents/BadooRecon";
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [dir stringByAppendingPathComponent:@"classes.txt"];
    NSMutableString *out = [NSMutableString stringWithFormat:@"# Badoo Class Map - %@\n", [NSDate date]];
    
    int numClasses = objc_getClassList(NULL, 0);
    Class *classes = (Class *)malloc(sizeof(Class) * numClasses);
    numClasses = objc_getClassList(classes, numClasses);
    
    for (int i = 0; i < numClasses; i++) {
        Class cls = classes[i];
        const char *name = class_getName(cls);
        if (!name) continue;
        NSString *className = [NSString stringWithUTF8String:name];
        
        BOOL relevant = NO;
        NSArray *kws = @[@"Chat", @"Message", @"Presence", @"User", @"Dialog", @"Socket", @"API", @"Network"];
        for (NSString *kw in kws) {
            if ([className rangeOfString:kw options:NSCaseInsensitiveSearch].location != NSNotFound) {
                relevant = YES; break;
            }
        }
        
        if (relevant) {
            [out appendFormat:@"\n## %@ : %@\n", className, class_getSuperclass(cls) ? [NSString stringWithUTF8String:class_getName(class_getSuperclass(cls))] : @"nil"];
            unsigned int methodCount;
            Method *methods = class_copyMethodList(cls, &methodCount);
            for (int j = 0; j < methodCount; j++) {
                [out appendFormat:@"  -%s\n", sel_getName(method_getName(methods[j]))];
            }
            free(methods);
        }
    }
    free(classes);
    [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    RCLog(@"Dumped class map to %@", path);
}

void RCDumpViewTree(UIView *view, int depth, NSMutableString *out) {
    if (!view || depth > 10) return;
    NSMutableString *indent = [NSMutableString string];
    for (int i = 0; i < depth; i++) [indent appendString:@"  "];
    [out appendFormat:@"%@<%@ %p> frame=%@ label=%@\n", indent, NSStringFromClass([view class]), view, NSStringFromCGRect(view.frame), view.accessibilityLabel ?: @""];
    for (UIView *sub in view.subviews) RCDumpViewTree(sub, depth + 1, out);
}

void RCDumpTopUI(void) {
    UIWindow *kw = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w.isKeyWindow && w != gReconWindow) { kw = w; break; }
            }
        }
    }
    if (!kw) kw = UIApplication.sharedApplication.keyWindow;
    if (!kw) { RCLog(@"No key window found."); return; }
    
    NSMutableString *out = [NSMutableString stringWithFormat:@"\n=== UI DUMP %@ ===\n", [NSDate date]];
    UIViewController *root = kw.rootViewController;
    while (root.presentedViewController) root = root.presentedViewController;
    
    [out appendFormat:@"ROOT VC: %@\n", NSStringFromClass([root class])];
    if (root.view) RCDumpViewTree(root.view, 0, out);
    
    NSString *path = [@"/var/mobile/Documents/BadooRecon" stringByAppendingPathComponent:@"ui_dump.txt"];
    [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    RCLog(@"Dumped UI to %@", path);
}

@interface ReconVC : UIViewController @end
@implementation ReconVC
- (void)viewDidLoad { [super viewDidLoad]; self.view.backgroundColor = UIColor.clearColor; }
@end

static void ReconTap(void) {
    RCDumpTopUI();
    gReconLabel.text = @"DUMPED!";
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        gReconLabel.text = @"RECON";
    });
}

void RCSetupHUD(void) {
    UIWindowScene *activeScene = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]] && s.activationState == UISceneActivationStateForegroundActive) {
            activeScene = (UIWindowScene *)s; break;
        }
    }
    if (!activeScene) {
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]]) { activeScene = (UIWindowScene *)s; break; }
        }
    }
    if (!activeScene) return;
    
    gReconWindow = [[UIWindow alloc] initWithWindowScene:activeScene];
    gReconWindow.windowLevel = UIWindowLevelAlert + 1000;
    gReconWindow.backgroundColor = UIColor.clearColor;
    gReconWindow.rootViewController = [ReconVC new];
    gReconWindow.hidden = NO;
    
    gReconLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 100, 44)];
    gReconLabel.text = @"RECON";
    gReconLabel.textAlignment = NSTextAlignmentCenter;
    gReconLabel.font = [UIFont boldSystemFontOfSize:16];
    gReconLabel.textColor = UIColor.whiteColor;
    gReconLabel.backgroundColor = [UIColor colorWithRed:0.9 green:0.1 blue:0.1 alpha:0.95];
    gReconLabel.layer.cornerRadius = 10;
    gReconLabel.layer.masksToBounds = YES;
    gReconLabel.userInteractionEnabled = YES;
    gReconLabel.center = CGPointMake(80, 120); 
    [gReconWindow addSubview:gReconLabel];
    
    class_addMethod([UILabel class], NSSelectorFromString(@"rc_tap"), (IMP)ReconTap, "v@:");
    [gReconLabel addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:gReconLabel action:NSSelectorFromString(@"rc_tap")]];
    
    RCLog(@"HUD successfully created.");
}

%hook UIViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    NSString *name = NSStringFromClass([self class]);
    if ([name.lowercaseString containsString:@"chat"] || [name.lowercaseString containsString:@"conversation"]) {
        RCLog(@"Chat screen appeared: %@", name);
        RCDumpTopUI();
    }
}
%end

%hook UIApplication
- (BOOL)sendAction:(SEL)action to:(id)target from:(id)sender forEvent:(UIEvent *)event {
    NSString *sel = NSStringFromSelector(action);
    NSString *senderClass = sender ? NSStringFromClass([sender class]) : @"nil";
    if ([sel.lowercaseString containsString:@"send"] || [senderClass.lowercaseString containsString:@"send"]) {
        RCLog(@"Tapped Send: %@ (Sender: %@)", sel, senderClass);
    }
    return %orig;
}
%end

%ctor {
    @autoreleasepool {
        RCLog(@"Tweak loaded.");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            RCSetupHUD();
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                RCDumpClassMap();
            });
        });
    }
}
