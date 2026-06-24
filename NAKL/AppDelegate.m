/*******************************************************************************
 * Copyright (c) 2012 Huy Phan <dachuy@gmail.com>
 * This file is part of NAKL project.
 *
 * NAKL is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * NAKL is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with NAKL.  If not, see <http://www.gnu.org/licenses/>.
 ******************************************************************************/

#import <Security/Security.h>
#import "AppDelegate.h"

@implementation AppDelegate

//@synthesize window = _window;
@synthesize preferencesController;
@synthesize eventTap;

uint64_t controlKeys = kCGEventFlagMaskCommand | kCGEventFlagMaskAlternate | kCGEventFlagMaskControl | kCGEventFlagMaskSecondaryFn | kCGEventFlagMaskHelp;

static char *separators[] = {
    "",                                     // VKM_OFF
    "!@#$%&)|\\-{}[]:\";<>,/'`~?.^*(+=",    // VKM_VNI
    "!@#$%&)|\\-:\";<>,/'`~?.^*(+="         // VKM_TELEX
};

KeyboardHandler *kbHandler;

static char rk = 0;
bool dirty;

/* Frontmost app bundle id, cached. Updated on the main thread via
   NSWorkspace activation notifications. The event tap callback must NOT call
   NSWorkspace itself: that is main-thread-only AppKit and querying it on every
   keystroke is slow + crashes intermittently on modern macOS. */
static NSString *gActiveAppBundleId = nil;

#pragma mark Initialization

+ (void)initialize
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *appDefs = [NSMutableDictionary dictionary];
    [appDefs setObject:[NSNumber numberWithInt:1] forKey:NAKL_KEYBOARD_METHOD];
    [defaults registerDefaults:appDefs];

    // Accessibility permissions are checked when creating the event tap,
    // which allows proper permission prompting on modern macOS.
}

- (void)applicationWillFinishLaunching:(NSNotification *)aNotification
{
    NSLog(@"NAKL starting up...");
    
    preferencesController = [[PreferencesController alloc] init];
    
    [AppData loadUserPrefs];
    [AppData loadHotKeys];
    [AppData loadShortcuts];
    [AppData loadExcludedApps];
    
    int method = (int)[[AppData sharedAppData].userPrefs integerForKey:NAKL_KEYBOARD_METHOD];
    for (id object in [statusMenu itemArray]) {
        [(NSMenuItem*) object setState:((NSMenuItem*) object).tag == method];
    }
    
    kbHandler = [[KeyboardHandler alloc] init];
    kbHandler.kbMethod = method;

    // Track the frontmost app on the main thread so the event tap callback can
    // read a cached bundle id instead of calling NSWorkspace per keystroke.
    gActiveAppBundleId = [[NSWorkspace sharedWorkspace] frontmostApplication].bundleIdentifier;
    [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserver:self
           selector:@selector(activeAppChanged:)
               name:NSWorkspaceDidActivateApplicationNotification
             object:nil];

    // Delay the event loop creation slightly to ensure proper initialization
    // This is especially important for standalone apps
    [self performSelector:@selector(startEventLoop) withObject:nil afterDelay:0.5];
    
    [self updateStatusItem];
}

- (void)activeAppChanged:(NSNotification *)note {
    NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
    gActiveAppBundleId = app.bundleIdentifier;
}

- (void)startEventLoop {
    NSLog(@"Starting event loop on main thread...");
    // Run on the main thread. The event tap callback calls AppKit, which is
    // main-thread-only; a background CFRunLoop caused intermittent crashes.
    [self eventLoop];
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    NSLog(@"NAKL finished launching");
    NSLog(@"Bundle ID: %@", [[NSBundle mainBundle] bundleIdentifier]);
    NSLog(@"Version: %@", [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"]);
    NSLog(@"Running from: %@", [[NSBundle mainBundle] bundlePath]);
    
    // Check if we're running in development or production
    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    if ([bundlePath containsString:@"DerivedData"]) {
        NSLog(@"Running in development mode (Xcode)");
    } else {
        NSLog(@"Running in production mode (standalone)");
    }
}

-(void)awakeFromNib {
    [super awakeFromNib];
    statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    [statusItem setMenu:statusMenu];


    NSSize imageSize;
    imageSize.width = 16;
    imageSize.height = 16;
    
    NSBundle *bundle = [NSBundle mainBundle];
    viStatusImage = [[NSImage alloc] initWithContentsOfFile: [bundle pathForResource: @"icon24" ofType: @"png"]];
    [viStatusImage setSize:imageSize];
    
    enStatusImage = [[NSImage alloc] initWithContentsOfFile: [bundle pathForResource: @"icon_blue_24" ofType: @"png"]];
    [enStatusImage setSize:imageSize];
}

#pragma mark Keyboard Handler

CGEventRef KeyHandler(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon)
{
    UniCharCount actualStringLength;
    UniCharCount maxStringLength = 1;
    UniChar chars[3];
    UniChar *x;
    long i;

    /* Read cached value; do not touch NSWorkspace from the tap callback. */
    NSString *activeAppBundleId = gActiveAppBundleId;

    uint64_t flag = CGEventGetFlags(event);
    
    if (flag & NAKL_MAGIC_NUMBER) {
        return event;
    }
    
    if ([[AppData sharedAppData].excludedApps objectForKey:activeAppBundleId]) {
        return event;
    }
    
    CGEventKeyboardGetUnicodeString(event, maxStringLength, &actualStringLength, chars);
    UniChar key = chars[0];
    
    switch (type) {
        case kCGEventKeyUp:
            if (rk == key) {
                chars[0] = XK_BackSpace;
                CGEventKeyboardSetUnicodeString(event, actualStringLength, chars);
                rk = 0;
            }
            break;
            
        case kCGEventTapDisabledByTimeout:
        case kCGEventTapDisabledByUserInput:
            // macOS disables the tap if the callback is too slow OR on certain
            // user input; re-enable in both cases or the app silently stops.
            CGEventTapEnable(((__bridge AppDelegate*) refcon).eventTap , TRUE);
            break;
            
        case kCGEventKeyDown:
        {
            ushort keycode = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
            
            if (flag & (controlKeys)) {
                bool validShortcut = false;
                if (((flag & controlKeys) == [AppData sharedAppData].toggleCombo.flags) && (keycode == [AppData sharedAppData].toggleCombo.code) )
                {
                    if (kbHandler.kbMethod == VKM_OFF) {
                        kbHandler.kbMethod = (int)[[AppData sharedAppData].userPrefs integerForKey:NAKL_KEYBOARD_METHOD];
                    } else {
                        kbHandler.kbMethod = VKM_OFF;
                    }
                    
                  [((__bridge AppDelegate*) refcon) updateCheckedItem];
                  [((__bridge AppDelegate*) refcon) updateStatusItem];
                    validShortcut = true;
                }
                
                if (((flag & controlKeys) == [AppData sharedAppData].switchMethodCombo.flags) && (keycode == [AppData sharedAppData].switchMethodCombo.code) ){
                    if (kbHandler.kbMethod == VKM_VNI) {
                        kbHandler.kbMethod = VKM_TELEX;
                    } else if (kbHandler.kbMethod == VKM_TELEX) {
                        kbHandler.kbMethod = VKM_VNI;
                    }
                    
                    if (kbHandler.kbMethod != VKM_OFF) {
                        [[AppData sharedAppData].userPrefs setValue:[NSNumber numberWithInt:kbHandler.kbMethod] forKey:NAKL_KEYBOARD_METHOD];
                      [((__bridge AppDelegate*) refcon) updateCheckedItem];
                      [((__bridge AppDelegate*) refcon) updateStatusItem];
                    }
                    validShortcut = true;
                }
                
                [kbHandler clearBuffer];
                
                if (validShortcut) return NULL;
                
                break;
            }
            
            /* TODO: Use keycode instead of value of character */
            switch (keycode) {
                case KC_Return:
                case KC_Return_Num:
                case KC_Home:
                case KC_Left:
                case KC_Up:
                case KC_Right:
                case KC_Down:
                case KC_End:
                case KC_Tab:
                case KC_BackSpace:
                case KC_Delete:
                case KC_Page_Up:
                case KC_Page_Down:
                    [kbHandler clearBuffer];
                    break;
                    
                default:
                    
                    if (kbHandler.kbMethod == VKM_OFF) {
                        break;
                    }
                    
                    char *sp = strchr(separators[kbHandler.kbMethod], key);
                    if (sp) {
                        [kbHandler clearBuffer];
                        break;
                    }
                    
                    switch([kbHandler addKey:key]) {
                        case -1:
                            
                            break;
                            
                        default:
                        {
                            x = kbHandler.kbBuffer+BACKSPACE_BUFFER-kbHandler.kbPLength;
                            for (i = 0;i<kbHandler.kbBLength + kbHandler.kbPLength;i++,x++) {
                                CGEventRef keyEventDown = CGEventCreateKeyboardEvent( NULL, 1, true);
                                CGEventRef keyEventUp = CGEventCreateKeyboardEvent(NULL, 1, false);
                                
                                int flag = (int) CGEventGetFlags(keyEventDown);
                                CGEventSetFlags(keyEventDown, NAKL_MAGIC_NUMBER | flag);
                                
                                flag = (int) CGEventGetFlags(keyEventUp);
                                CGEventSetFlags(keyEventUp,NAKL_MAGIC_NUMBER | flag);
                                if (*x == '\b') {
                                    CGEventSetIntegerValueField(keyEventDown, kCGKeyboardEventKeycode, 0x33);
                                    CGEventSetIntegerValueField(keyEventUp, kCGKeyboardEventKeycode, 0x33);
                                } else {
                                    CGEventKeyboardSetUnicodeString(keyEventDown, 1, x);
                                    CGEventKeyboardSetUnicodeString(keyEventUp, 1, x);
                                }
                                
                                CGEventTapPostEvent(proxy, keyEventDown);
                                CGEventTapPostEvent(proxy, keyEventUp);
                                
                                CFRelease(keyEventDown);
                                CFRelease(keyEventUp);
                            }
                            return NULL;
                        }
                    }
            }
            break;
        }
            
        case kCGEventLeftMouseDown:
        case kCGEventRightMouseDown:
        case kCGEventOtherMouseDown:
            [kbHandler clearBuffer];
            break;
            
        default:
            break;
    }
    
    return event;
}

- (void) eventLoop {
    CGEventMask        eventMask;
    CFRunLoopSourceRef runLoopSource;
    
    NSLog(@"Starting event loop - checking accessibility permissions...");
    
    // Check accessibility permissions first WITHOUT prompting
    NSDictionary *options = @{(__bridge id) kAXTrustedCheckOptionPrompt: @NO};
    BOOL accessibilityEnabled = AXIsProcessTrustedWithOptions((CFDictionaryRef)options);
    NSLog(@"Accessibility permissions check: %@", accessibilityEnabled ? @"GRANTED" : @"DENIED");

    if (!accessibilityEnabled) {
        NSLog(@"NAKL requires accessibility permissions to function properly.");
        NSLog(@"Showing one-time setup dialog to user...");
        
        // Show our single, clear setup dialog
        dispatch_async(dispatch_get_main_queue(), ^{
            NSAlert *alert = [[NSAlert alloc] init];
            [alert setMessageText:@"Welcome to NAKL"];
            [alert setInformativeText:@"NAKL is a Vietnamese keyboard input method that needs permission to monitor keyboard events.\n\nTo enable NAKL:\n\n1. Click 'Open System Preferences' below\n2. Go to Security & Privacy → Privacy → Accessibility\n3. Click the lock icon and enter your password\n4. Find NAKL in the list and check the box next to it\n\nNAKL will start working automatically once you enable it."];
            [alert addButtonWithTitle:@"Open System Preferences"];
            [alert addButtonWithTitle:@"I'll Do It Later"];
            [alert addButtonWithTitle:@"Quit"];
            
            NSModalResponse response = [alert runModal];
            
            if (response == NSAlertFirstButtonReturn) {
                // Open System Preferences to Accessibility panel
                [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
                // Start checking for permission in background
                [self performSelector:@selector(retryEventTapCreation) withObject:nil afterDelay:3.0];
            } else if (response == NSAlertSecondButtonReturn) {
                // User will do it later, start checking periodically
                [self performSelector:@selector(retryEventTapCreation) withObject:nil afterDelay:10.0];
            } else {
                [NSApp terminate:self];
            }
        });
        return;
    }
    
    NSLog(@"Accessibility permissions granted, attempting to create event tap...");
    
    eventMask = ((1 << kCGEventKeyDown) | (1 << kCGEventKeyUp) |
                 (1 << kCGEventLeftMouseDown) |
                 (1 << kCGEventRightMouseDown) |
                 (1 << kCGEventOtherMouseDown)
                 );
    
    eventTap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, 0,
                                eventMask, KeyHandler, (__bridge void * _Nullable)(self));
    if (!eventTap) {
        NSLog(@"Failed to create event tap. This usually means accessibility permissions are not properly granted.");
        NSLog(@"Bundle identifier: %@", [[NSBundle mainBundle] bundleIdentifier]);
        NSLog(@"Executable path: %@", [[NSBundle mainBundle] executablePath]);
        
        dispatch_async(dispatch_get_main_queue(), ^{
            NSAlert *alert = [[NSAlert alloc] init];
            [alert setMessageText:@"Permission Issue"];
            [alert setInformativeText:@"NAKL still can't access keyboard events. This usually means:\n\n• Accessibility permission isn't properly enabled\n• The app needs to be restarted after enabling permission\n• macOS needs a moment to apply the changes\n\nPlease check System Preferences again and restart NAKL if needed."];
            [alert addButtonWithTitle:@"Open System Preferences"];
            [alert addButtonWithTitle:@"Retry Now"];
            [alert addButtonWithTitle:@"Quit"];
            
            NSModalResponse response = [alert runModal];
            
            if (response == NSAlertFirstButtonReturn) {
                [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
                [self performSelector:@selector(retryEventTapCreation) withObject:nil afterDelay:2.0];
            } else if (response == NSAlertSecondButtonReturn) {
                [self performSelector:@selector(retryEventTapCreation) withObject:nil afterDelay:1.0];
            } else {
                [NSApp terminate:self];
            }
        });
        return;
    }
    
    NSLog(@"Event tap created successfully. NAKL is now active.");
    
    runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, kCFRunLoopCommonModes);
    CGEventTapEnable(eventTap, true);
    if (runLoopSource) CFRelease(runLoopSource);
    // No CFRunLoopRun() here: the main run loop (NSApplicationMain) is already
    // running and now drives the tap.
}

- (void) retryEventTapCreation {
    // Check if accessibility permissions have been granted (without prompting)
    NSDictionary *options = @{(__bridge id) kAXTrustedCheckOptionPrompt: @NO};
    BOOL accessibilityEnabled = AXIsProcessTrustedWithOptions((CFDictionaryRef)options);

    NSLog(@"Retry permission check: %@", accessibilityEnabled ? @"GRANTED" : @"DENIED");
    
    if (accessibilityEnabled && !eventTap) {
        NSLog(@"Accessibility permissions granted, attempting to create event tap...");
        [self eventLoop];
    } else if (!accessibilityEnabled) {
        // Schedule another check in 3 seconds (without showing alerts)
        NSLog(@"Still waiting for accessibility permissions...");
        [self performSelector:@selector(retryEventTapCreation) withObject:nil afterDelay:3.0];
    }
}

#pragma mark GUI

- (void) updateCheckedItem {
    int method = kbHandler.kbMethod;
    for (id object in [statusMenu itemArray]) {
        [(NSMenuItem*) object setState:((NSMenuItem*) object).tag == method];
    }
}

- (void) updateStatusItem {
    int method = kbHandler.kbMethod;
    switch (method) {
        case VKM_VNI:
        case VKM_TELEX:
            statusItem.button.image = viStatusImage;
            break;

        default:
            statusItem.button.image = enStatusImage;
            break;
    }
}

-(IBAction)showPreferences:(id)sender{
    if(!self.preferencesController)
        self.preferencesController = [[PreferencesController alloc] initWithWindowNibName:@"Preferences"];
    
    [NSApp activateIgnoringOtherApps:YES];
    [self.preferencesController showWindow:self];
    [self.preferencesController.window center];
}

- (IBAction) methodSelected:(id)sender {
    for (id object in [statusMenu itemArray]) {
        [(NSMenuItem*) object setState:NSControlStateValueOff];
    }
    
    [(NSMenuItem*) sender setState:NSControlStateValueOn];
    
    int method;
    
    if ([[(NSMenuItem*) sender title] compare:@"VNI"] == 0)
    {
        method = VKM_VNI;
    }
    else if ([[(NSMenuItem*) sender title] compare:@"Telex"] == 0)
    {
        method = VKM_TELEX;
    }
    else
    {
        method = VKM_OFF;
    }
    
    kbHandler.kbMethod = method;
    if (method != VKM_OFF)
    {
        [[AppData sharedAppData].userPrefs setValue:[NSNumber numberWithInt:method] forKey:NAKL_KEYBOARD_METHOD];
    }
    
    [self updateStatusItem];
}

#pragma mark -

- (IBAction) quit:(id)sender
{
    // Tap now runs on the main run loop; just terminate. Stopping the main
    // loop here would interfere with normal teardown.
    [NSApp terminate:self];
}

@end
