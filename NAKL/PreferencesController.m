#import "PreferencesController.h"
#import "ShortcutRecorder/SRRecorderControl.h"
#import "PTHotKeyCenter.h"
#import "PTHotKey.h"
#import "NSFileManager+DirectoryLocations.h"
#import <ServiceManagement/ServiceManagement.h>

@implementation PreferencesController

@synthesize toggleHotKey = _toggleHotKey;
@synthesize switchMethodHotKey = _switchMethodHotKey;
@synthesize versionString;
@synthesize shortcuts;

- (id)init {
    if (![super initWithWindowNibName:@"Preferences"])
        return nil;

    NSString *version = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    NSString *buildNumber = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"];

    self.versionString = [NSString stringWithFormat:@"Version %@ (build %@)", version, buildNumber];

    return self;
}

- (void)windowDidLoad {
    [super windowDidLoad];
    [self.toggleHotKey setKeyCombo:[AppData sharedAppData].toggleCombo];
    [self.switchMethodHotKey setKeyCombo:[AppData sharedAppData].switchMethodCombo];
    [self.shortcuts setContent:[AppData sharedAppData].shortcuts];
}

- (void)windowWillClose:(NSNotification *)notification {
    [self saveSetting];
}

- (BOOL)shortcutRecorder:(SRRecorderControl *)aRecorder isKeyCode:(NSInteger)keyCode andFlagsTaken:(NSUInteger)flags reason:(NSString **)aReason {
    return NO;
}

- (void)shortcutRecorder:(SRRecorderControl *)aRecorder keyComboDidChange:(KeyCombo)newKeyCombo {
    PTKeyCombo *keyCombo = [[PTKeyCombo alloc] initWithKeyCode:newKeyCombo.code modifiers:newKeyCombo.flags];
    if (aRecorder == self.toggleHotKey) {
        [[AppData sharedAppData].userPrefs setObject:[keyCombo plistRepresentation] forKey:NAKL_TOGGLE_HOTKEY];
        [AppData sharedAppData].toggleCombo = newKeyCombo;
    } else {
        [[AppData sharedAppData].userPrefs setObject:[keyCombo plistRepresentation] forKey:NAKL_SWITCH_METHOD_HOTKEY];
        [AppData sharedAppData].switchMethodCombo = newKeyCombo;
    }
}

// Legacy login-item helpers for macOS 11 / 12, which predate SMAppService.
// LSSharedFileList is deprecated; the warnings are intentionally suppressed
// here because this is the documented fallback path only.
- (void)addAppsAsLoginItem {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSString *appPath = [[NSBundle mainBundle] bundlePath];
    NSURL *url = [NSURL fileURLWithPath:appPath];

    LSSharedFileListRef loginItems = LSSharedFileListCreate(NULL,
        kLSSharedFileListSessionLoginItems, NULL);
    if (loginItems) {
        LSSharedFileListItemRef item = LSSharedFileListInsertItemURL(loginItems,
            kLSSharedFileListItemLast, NULL, NULL,
            (__bridge CFURLRef)url, NULL, NULL);
        if (item) {
            CFRelease(item);
        }
        CFRelease(loginItems);
    }
#pragma clang diagnostic pop
}

- (void)removeAppFromLoginItem {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSString *appPath = [[NSBundle mainBundle] bundlePath];

    LSSharedFileListRef loginItems = LSSharedFileListCreate(NULL,
        kLSSharedFileListSessionLoginItems, NULL);

    if (loginItems) {
        UInt32 seedValue;
        NSArray *loginItemsArray = (__bridge_transfer NSArray *)LSSharedFileListCopySnapshot(loginItems, &seedValue);
        for (id item in loginItemsArray) {
            LSSharedFileListItemRef itemRef = (__bridge LSSharedFileListItemRef)item;
            CFURLRef itemURL = NULL;
            if (LSSharedFileListItemResolve(itemRef, 0, &itemURL, NULL) == noErr) {
                NSString *itemPath = [(__bridge NSURL *)itemURL path];
                if ([itemPath isEqualToString:appPath]) {
                    LSSharedFileListItemRemove(loginItems, itemRef);
                }
                if (itemURL) CFRelease(itemURL);
            }
        }
        CFRelease(loginItems);
    }
#pragma clang diagnostic pop
}

- (IBAction)startupOptionClick:(id)sender {
    BOOL enable = (((NSButton *)sender).state == NSControlStateValueOn);

    // macOS 13+: register the main app itself as a login item via the modern,
    // non-deprecated ServiceManagement API (no helper bundle required).
    if (@available(macOS 13.0, *)) {
        NSError *error = nil;
        BOOL ok = enable
            ? [[SMAppService mainAppService] registerAndReturnError:&error]
            : [[SMAppService mainAppService] unregisterAndReturnError:&error];
        if (!ok || error) {
            NSLog(@"Login item %@ failed: %@",
                  enable ? @"register" : @"unregister", error);
        }
        return;
    }

    // macOS 11 / 12 fallback.
    if (enable) {
        [self addAppsAsLoginItem];
    } else {
        [self removeAppFromLoginItem];
    }
}

- (void)saveSetting {
    NSString *filePath = [[[NSFileManager defaultManager] applicationSupportDirectory] stringByAppendingPathComponent:@"shortcuts.setting"];
    NSData *theData = [NSKeyedArchiver archivedDataWithRootObject:[AppData sharedAppData].shortcuts requiringSecureCoding:NO error:nil];
    [theData writeToFile:filePath atomically:YES];

    [[AppData sharedAppData].shortcutDictionary removeAllObjects];
    for (ShortcutSetting *s in [AppData sharedAppData].shortcuts) {
        [[AppData sharedAppData].shortcutDictionary setObject:s.text forKey:s.shortcut];
    }
}

@end
