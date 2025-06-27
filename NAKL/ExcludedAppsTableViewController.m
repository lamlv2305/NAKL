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

#import "ExcludedAppsTableViewController.h"
#import "AppData.h"

@implementation ExcludedAppsTableViewController

- (id)init
{
    self = [super init];
    if (self) {
        [tableView usesAlternatingRowBackgroundColors];
    }
    return self;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    return [[[AppData sharedAppData].excludedApps allKeys] count];
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
    return [[AppData sharedAppData].excludedApps objectForKey:[[[AppData sharedAppData].excludedApps allKeys] objectAtIndex:row]];
}

- (IBAction)add:(id)sender
{
    NSOpenPanel* dialog = [NSOpenPanel openPanel];
    [dialog setCanChooseFiles:YES];
    [dialog setAllowsMultipleSelection:YES];
    [dialog setCanChooseDirectories:NO];
    [dialog setDirectoryURL:[NSURL fileURLWithPath:@"/Applications"]];

    if ([dialog runModal] == NSModalResponseOK) {
        NSArray<NSURL *> *selectedURLs = [dialog URLs];
        for (NSURL *url in selectedURLs) {
            NSString *path = [url path];
            NSDictionary *plistData = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Contents/Info.plist"]];
            NSString *appBundleIdentifier = plistData[@"CFBundleIdentifier"];
            NSString *appName = plistData[@"CFBundleName"];
            if ((appName == nil) || [appName isEqualToString:@""]) {
                appName = [[path lastPathComponent] stringByDeletingPathExtension];
            }
            if ((appBundleIdentifier != nil) && ![[AppData sharedAppData].excludedApps objectForKey:appBundleIdentifier]) {
                [[AppData sharedAppData].excludedApps setObject:appName forKey:appBundleIdentifier];
                [self.list addObject:appBundleIdentifier];
            }
        }
        [[AppData sharedAppData].userPrefs setObject:[AppData sharedAppData].excludedApps forKey:NAKL_EXCLUDED_APPS];
        [tableView reloadData];
    }
}

- (IBAction)remove:(id)sender
{
    NSInteger row = [tableView selectedRow];
    [tableView abortEditing];
    if (row != -1) {
        NSString* appBundleIdentifier = [[[AppData sharedAppData].excludedApps allKeys] objectAtIndex:row];
        [[AppData sharedAppData].excludedApps removeObjectForKey:appBundleIdentifier];
    }
    [tableView reloadData];
    [[AppData sharedAppData].userPrefs setObject:[AppData sharedAppData].excludedApps forKey:NAKL_EXCLUDED_APPS];
}

@end
