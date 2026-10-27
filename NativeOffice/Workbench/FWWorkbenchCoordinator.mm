#import "FWWorkbenchCoordinator.h"
#import "FileWorkbenchNative-Swift.h"
#import "ASCCommonViewController.h"
#import "ASCConstants.h"
#import "ASCEventsController.h"
#import "ASCTabView.h"
#import "AppDelegate.h"
#import <objc/runtime.h>

static char FWCoordinatorKey;

@interface AppDelegate (FWMenuActions)
- (IBAction)onMenuSave:(id)sender;
- (IBAction)onMenuSaveAs:(id)sender;
@end

@interface FWWorkbenchCoordinator ()
@property(nonatomic, weak) ASCCommonViewController *owner;
@property(nonatomic) FWBrowserHost *browser;
@property(nonatomic) NSMutableDictionary<NSString *, FWDocumentHost *> *documents;
@property(nonatomic) NSMutableDictionary<NSString *, NSNumber *> *pendingURLs;
@property(nonatomic) NSMutableSet<NSString *> *closing;
@property(nonatomic) NSString *previewID;
@property(nonatomic) NSString *lastPreviewRequest;
@property(nonatomic) NSTabView *editorTabs;
@property(nonatomic) NSMutableSet<NSString *> *readyOfficeTabs;
@property(nonatomic) BOOL closingAll;
@property(nonatomic) NSString *saveReturnRequest;
@property(nonatomic) NSString *saveReturnTabID;
@end

@implementation FWWorkbenchCoordinator
+ (instancetype)forController:(ASCCommonViewController *)controller {
    return controller ? objc_getAssociatedObject(controller, &FWCoordinatorKey) : nil;
}
+ (instancetype)current {
    NSWindow *window = NSApp.keyWindow ?: NSApp.mainWindow;
    if (window.sheetParent) window = window.sheetParent;
    id controller = window.contentViewController;
    return [controller isKindOfClass:ASCCommonViewController.class] ? [self forController:controller] : nil;
}
+ (instancetype)installInController:(ASCCommonViewController *)controller {
    FWWorkbenchCoordinator *existing = [self forController:controller];
    if (existing) return existing;
    FWWorkbenchCoordinator *coordinator = [self new];
    coordinator.owner = controller;
    coordinator.documents = [NSMutableDictionary dictionary];
    coordinator.pendingURLs = [NSMutableDictionary dictionary];
    coordinator.closing = [NSMutableSet set];
    coordinator.readyOfficeTabs = [NSMutableSet set];
    objc_setAssociatedObject(controller, &FWCoordinatorKey, coordinator, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [coordinator installLayout];
    [coordinator installMenu];
    [coordinator observeOfficeState];
    return coordinator;
}
+ (BOOL)isNativeTab:(ASCTabView *)tab { return [tab.params[@"fwNative"] boolValue]; }
+ (BOOL)isOfficeURL:(NSURL *)url {
    return [@[@"word", @"spreadsheet", @"presentation"] containsObject:[FWDocumentHost kindForURL:url]];
}
+ (NSURL *)saveDirectoryForOfficeViewID:(int)viewID {
    for (NSWindow *window in NSApp.windows) {
        if ([window.contentViewController isKindOfClass:ASCCommonViewController.class]) {
            ASCCommonViewController *owner = (ASCCommonViewController *)window.contentViewController;
            if ([owner tabViewWithId:viewID]) return [self forController:owner].browser.currentDirectory;
        }
    }
    return nil;
}
- (FWDocumentHost *)selectedDocument {
    if (self.browser.hasFilePreview) return self.browser.previewDocument;
    return self.documents[self.owner.tabsControl.selectedTab.uuid ?: @""];
}
- (FWDocumentHost *)nativeDocumentForTab:(ASCTabView *)tab { return self.documents[tab.uuid ?: @""]; }
- (BOOL)hasSelectedNativeDocument { return self.browser.hasFilePreview || self.selectedDocument != nil; }
- (BOOL)hasBusyDocuments {
    if (self.browser.previewBusy) return YES;
    for (FWDocumentHost *document in self.documents.allValues) if (document.busy) return YES;
    return self.closingAll || self.closing.count > 0;
}
- (BOOL)prepareToCloseApplication:(BOOL)application {
    // 临时预览不属于上游标签集合；窗口关闭和退出也必须先经过同一个保存保护门。
    if (self.browser.hasFilePreview) {
        if (self.closingAll) return NO;
        self.closingAll = YES;
        [self.browser requestClosePreviewWithCompletion:^(BOOL closed) {
            self.closingAll = NO;
            if (!closed) { [self.owner fwCancelPendingClose]; return; }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (application) [NSApp terminate:nil];
                else [self.owner.view.window performClose:nil];
            });
        }];
        return NO;
    }
    if (self.documents.count == 0) return YES;
    if (self.hasBusyDocuments) { NSBeep(); return NO; }
    self.closingAll = YES;
    [self closeNextNativeForApplication:application];
    return NO;
}
- (void)closeNextNativeForApplication:(BOOL)application {
    ASCTabView *next = nil;
    for (ASCTabView *tab in self.owner.tabsControl.tabs) {
        if (self.documents[tab.uuid]) { next = tab; break; }
    }
    if (!next) {
        self.closingAll = NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (application) [NSApp terminate:nil];
            else [self.owner.view.window performClose:nil];
        });
        return;
    }
    ASCTabView *captured = next;
    FWDocumentHost *capturedHost = self.documents[captured.uuid];
    [self.owner.tabsControl selectTab:captured];
    // 即使 dirty 尚未回传，也先同步真实编辑器再判断是否需要保存；批量退出不能只读缓存标志。
    [capturedHost requestCloseIn:self.browser.currentDirectory completion:^(BOOL closed) {
        if (!closed) {
            self.closingAll = NO;
            [self.owner fwCancelPendingClose];
            return;
        }
        if (self.documents[captured.uuid] == capturedHost)
            [self.owner.tabsControl removeTab:captured selected:NO animated:NO];
        [self closeNextNativeForApplication:application];
    }];
}
- (BOOL)hasChangesForTab:(ASCTabView *)tab {
    FWDocumentHost *document = self.documents[tab.uuid];
    return document.modified || document.busy;
}

- (void)installLayout {
    ASCCommonViewController *owner = self.owner;
    NSTabView *tabs = owner.tabView;
    NSView *parent = tabs.superview;
    // CEF 按 NSTabViewItem.view 的直接子视图定位文档。这里只移动整个 tabView，
    // 保留原窗口控制器、标签项、CEF 视图和退出保存链，同时由协调器维持强引用。
    self.editorTabs = tabs;
    for (NSLayoutConstraint *constraint in parent.constraints.copy) {
        if (constraint.firstItem == tabs || constraint.secondItem == tabs) constraint.active = NO;
    }
    [tabs removeFromSuperview];
    __weak typeof(self) weakSelf = self;
    self.browser = [[FWBrowserHost alloc] initWithEditorView:tabs openHandler:^(NSURL *url, BOOL pinned) {
        [weakSelf openURL:url pinned:pinned];
    } commandHandler:^(NSString *command) {
        [weakSelf performBrowserCommand:command];
    }];
    [owner addChildViewController:self.browser];
    NSView *browserView = self.browser.view;
    browserView.translatesAutoresizingMaskIntoConstraints = NO;
    [parent addSubview:browserView];
    [NSLayoutConstraint activateConstraints:@[
        [browserView.leadingAnchor constraintEqualToAnchor:parent.leadingAnchor],
        [browserView.trailingAnchor constraintEqualToAnchor:parent.trailingAnchor],
        [browserView.topAnchor constraintEqualToAnchor:parent.topAnchor],
        [browserView.bottomAnchor constraintEqualToAnchor:parent.bottomAnchor]
    ]];
    owner.view.window.appearance = nil; // 浏览与原生工作层跟随系统浅色/深色外观。
    // ContentView 挂载后统一设置欢迎页默认尺寸与分阶段最小值，避免覆盖用户缩放。
    [self updateEditorState];
}

- (void)performBrowserCommand:(NSString *)command {
    if (self.closingAll) return;
    if (self.browser.hasFilePreview && ([command hasPrefix:@"new:"] || [command isEqualToString:@"open"] || [command isEqualToString:@"recoverDrafts"])) {
        [self.browser requestClosePreviewWithCompletion:^(BOOL closed) { if (closed) [self performBrowserCommand:command]; }];
        return;
    }
    if ([command hasPrefix:@"new:"]) {
        NSMenuItem *item = [NSMenuItem new];
        item.representedObject = [command substringFromIndex:4];
        [self createDocument:item];
    } else if ([command isEqualToString:@"recoverDrafts"]) [self recoverDrafts:nil];
    else if ([command isEqualToString:@"open"]) [self openPanel];
    else if ([command isEqualToString:@"save"]) [self saveFromButton:nil];
    else if ([command isEqualToString:@"saveAs"]) [self saveAsFromButton:nil];
    else if ([command isEqualToString:@"saveAndReturn"]) [self saveAndReturnSelected];
    else if ([command isEqualToString:@"export"]) [self exportSelected:nil];
    else if ([command isEqualToString:@"undo"]) [self undoSelected:nil];
    else if ([command isEqualToString:@"redo"]) [self redoSelected:nil];
    else if ([command isEqualToString:@"find"]) [self findSelected:nil];
    else if ([command isEqualToString:@"close"]) {
        if (self.browser.hasFilePreview) { [self.browser requestClosePreviewWithCompletion:^(BOOL closed) {}]; return; }
        // 与标题栏关闭按钮走同一委托，不能直接 removeTab 绕过未保存和繁忙保护。
        ASCTabView *tab = self.owner.tabsControl.selectedTab;
        if ([tab.delegate respondsToSelector:@selector(tabDidClose:)]) [tab.delegate tabDidClose:tab];
    }
}

- (void)observeOfficeState {
    for (NSString *name in @[CEFEventNameModifyChanged, CEFEventNameTabEditorNameChanged,
                             CEFEventNameEditorDocumentReady, CEFEventNameSave,
                             CEFEventNameStartSaveDialog, CEFEventNameEndSaveDialog]) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(officeStateChanged:)
                                                     name:name object:nil];
    }
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
- (void)officeStateChanged:(NSNotification *)notification {
    NSString *viewID = [notification.userInfo[@"viewId"] description];
    ASCTabView *tab = [self.owner.tabsControl tabWithUUID:viewID];
    if (!tab || [FWWorkbenchCoordinator isNativeTab:tab]) return;
    // 等上游通知处理完成再读取 CEF.data；后台保存/dirty 回调只更新状态，不切换页面。
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([notification.name isEqualToString:CEFEventNameEditorDocumentReady])
            [self.readyOfficeTabs addObject:tab.uuid];
        if ([notification.name isEqualToString:CEFEventNameSave] && ![notification.userInfo[@"cancel"] boolValue])
            [self.browser refreshDirectory];
        if ([notification.name isEqualToString:CEFEventNameSave] && [self.saveReturnTabID isEqualToString:tab.uuid]) {
            if ([notification.userInfo[@"cancel"] boolValue]) [self cancelSaveReturn];
            else [self finishOfficeSaveReturn:tab request:self.saveReturnRequest deadline:[NSDate dateWithTimeIntervalSinceNow:30]];
        }
        [self updateEditorState];
    });
}

- (NSMenu *)newMenu {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"新建"];
    NSArray *titles = @[@"Word 文档", @"Excel 工作簿", @"PowerPoint 演示文稿", @"Markdown", @"纯文本", @"代码", @"JSON", @"YAML", @"CSV 表格", @"从图片生成 PDF…"];
    NSArray *kinds = @[@"word", @"spreadsheet", @"presentation", @"markdown", @"text", @"code", @"json", @"yaml", @"csv", @"pdf"];
    for (NSUInteger index = 0; index < kinds.count; index++) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:titles[index] action:@selector(createDocument:) keyEquivalent:@""];
        item.representedObject = kinds[index]; item.target = self; [menu addItem:item];
    }
    return menu;
}
- (void)installMenu {
    // Storyboard 的应用菜单名称是静态值，需与最终包的名称同步。
    NSString *appName = NSBundle.mainBundle.infoDictionary[@"CFBundleDisplayName"] ?: @"FileDeck";
    NSMenuItem *appMenu = NSApp.mainMenu.itemArray.firstObject;
    appMenu.title = appName;
    appMenu.submenu.title = appName;
    if ([NSApp.mainMenu itemWithTag:471009]) return;
    NSMenuItem *entry = [[NSMenuItem alloc] initWithTitle:@"工作台" action:nil keyEquivalent:@""];
    entry.tag = 471009;
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"工作台"];
    NSMenuItem *newItem = [[NSMenuItem alloc] initWithTitle:@"新建" action:nil keyEquivalent:@""];
    newItem.submenu = self.newMenu; [menu addItem:newItem];
    for (NSArray *row in @[@[@"打开…", @"openFromButton:", @""], @[@"恢复未保存草稿…", @"recoverDrafts:", @""], @[@"导出…", @"exportSelected:", @""],
                            @[@"查找与替换", @"findSelected:", @""], @[@"撤销", @"undoSelected:", @""],
                            @[@"重做", @"redoSelected:", @""], @[@"固定当前标签", @"pinSelected:", @""]]) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:row[0] action:NSSelectorFromString(row[1]) keyEquivalent:row[2]];
        item.target = self; [menu addItem:item];
    }
    entry.submenu = menu;
    [NSApp.mainMenu insertItem:entry atIndex:MIN(2, NSApp.mainMenu.numberOfItems)];
}
- (void)showNewMenu:(NSButton *)sender { [self.newMenu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSHeight(sender.bounds)) inView:sender]; }
- (void)createDocument:(NSMenuItem *)sender {
    if (self.browser.hasFilePreview) {
        [self.browser requestClosePreviewWithCompletion:^(BOOL closed) { if (closed) [self createDocument:sender]; }];
        return;
    }
    FWWorkbenchCoordinator *coordinator = [FWWorkbenchCoordinator current] ?: self;
    if (coordinator.closingAll) return;
    [coordinator.browser showEditor];
    coordinator.lastPreviewRequest = nil;
    NSString *kind = sender.representedObject;
    NSDictionary *office = @{@"word":@"word", @"spreadsheet":@"cell", @"presentation":@"slide"};
    if (office[kind]) {
        [[NSNotificationCenter defaultCenter] postNotificationName:CEFEventNameCreateTab object:nil
            userInfo:@{@"action":@(ASCTabActionCreateLocalFile), @"type":office[kind], @"active":@YES}];
    } else [coordinator openNativeURL:nil kind:kind pinned:YES];
}
// 恢复列表始终可从欢迎页或工作台菜单进入，不自动覆盖或静默打开用户文档。
- (void)recoverDrafts:(id)sender {
    if (self.closingAll) return;
    if (self.browser.hasFilePreview) {
        [self.browser requestClosePreviewWithCompletion:^(BOOL closed) { if (closed) [self recoverDrafts:sender]; }];
        return;
    }
    __weak typeof(self) weakSelf = self;
    [FWDocumentHost presentDraftRecoveryIn:self.owner.view.window completion:^(FWDocumentHost *host) {
        FWWorkbenchCoordinator *strongSelf = weakSelf;
        if (!host || !strongSelf.owner.view.window || strongSelf.closingAll) return;
        [strongSelf.browser showEditor];
        [strongSelf replaceCleanPreview];
        ASCTabView *tab = [[ASCTabView alloc] initWithFrame:NSZeroRect];
        tab.uuid = [@"fw:" stringByAppendingString:NSUUID.UUID.UUIDString];
        tab.title = host.documentTitle;
        tab.params = [@{@"fwNative":@YES, @"fwPreview":@NO} mutableCopy];
        strongSelf.documents[tab.uuid] = host;
        [strongSelf.owner.tabsControl addTab:tab selected:YES];
        host.stateDidChange = ^{ [weakSelf updateTab:tab]; };
        [strongSelf updateTab:tab];
    }];
}
- (void)openPanel {
    if (self.browser.hasFilePreview) {
        [self.browser requestClosePreviewWithCompletion:^(BOOL closed) { if (closed) [self openPanel]; }];
        return;
    }
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES; panel.canChooseDirectories = NO; panel.allowsMultipleSelection = YES;
    panel.directoryURL = self.browser.currentDirectory;
    [panel beginSheetModalForWindow:self.owner.view.window completionHandler:^(NSModalResponse response) {
        if (response == NSModalResponseOK) for (NSURL *url in panel.URLs) [self openURL:url pinned:YES];
    }];
}
- (void)openURL:(NSURL *)url pinned:(BOOL)pinned {
    if (self.closingAll) return;
    if (self.browser.hasFilePreview) {
        [self.browser requestClosePreviewWithCompletion:^(BOOL closed) { if (closed) [self openURL:url pinned:pinned]; }];
        return;
    }
    if (!url.isFileURL) return;
    [self.browser showEditor];
    url = url.URLByStandardizingPath;
    // 异步文本读取可能晚于后一次 Office 点击完成；旧预览不能抢回当前选择。
    self.lastPreviewRequest = url.path;
    for (ASCTabView *tab in self.owner.tabsControl.tabs) {
        NSString *path = self.documents[tab.uuid].documentURL.path ?: tab.params[@"path"];
        if ([path isEqualToString:url.path]) {
            [self.owner.tabsControl selectTab:tab];
            if (pinned) [self pinTab:tab];
            return;
        }
    }
    NSString *kind = [FWDocumentHost kindForURL:url];
    if ([FWWorkbenchCoordinator isOfficeURL:url]) {
        [self replaceCleanPreview];
        [[NSNotificationCenter defaultCenter] postNotificationName:CEFEventNameCreateTab object:nil
            userInfo:@{@"action":@(ASCTabActionOpenLocalFile), @"path":url.path,
                       @"active":@YES, @"fwRouted":@YES, @"fwPreview":@(!pinned)}];
    } else [self openNativeURL:url kind:kind pinned:pinned];
}
- (void)openNativeURL:(NSURL *)url kind:(NSString *)kind pinned:(BOOL)pinned {
    NSString *key = url.path;
    if (key && self.pendingURLs[key]) {
        if (pinned) self.pendingURLs[key] = @YES;
        return;
    }
    if (key) self.pendingURLs[key] = @(pinned);
    if (!pinned) self.lastPreviewRequest = key;
    __weak typeof(self) weakSelf = self;
    [FWDocumentHost openDocumentAt:url kind:kind completion:^(FWDocumentHost *host, NSError *error) {
        FWWorkbenchCoordinator *strongSelf = weakSelf;
        if (!strongSelf) return;
        BOOL keep = pinned || (key && [strongSelf.pendingURLs[key] boolValue]);
        if (key) [strongSelf.pendingURLs removeObjectForKey:key];
        if (!strongSelf.owner.view.window || strongSelf.closingAll) return;
        if (!keep && ![key isEqualToString:strongSelf.lastPreviewRequest]) return;
        if (!host) {
            if (error) [strongSelf.owner.view.window presentError:error];
            return;
        }
        [strongSelf replaceCleanPreview];
        ASCTabView *tab = [[ASCTabView alloc] initWithFrame:NSZeroRect];
        tab.uuid = [@"fw:" stringByAppendingString:NSUUID.UUID.UUIDString];
        tab.title = host.documentTitle;
        tab.params = [@{@"fwNative":@YES, @"fwKind":kind, @"fwPreview":@(!keep)} mutableCopy];
        strongSelf.documents[tab.uuid] = host;
        if (!keep) strongSelf.previewID = tab.uuid;
        [strongSelf.owner.tabsControl addTab:tab selected:YES];
        host.stateDidChange = ^{ [weakSelf updateTab:tab]; };
        [strongSelf updateTab:tab];
    }];
}
- (BOOL)addNativeTab:(ASCTabView *)tab {
    FWDocumentHost *host = self.documents[tab.uuid];
    if (!host) return NO;
    [self.owner addChildViewController:host];
    NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:tab.uuid];
    item.label = host.documentTitle;
    [self.owner.tabView addTabViewItem:item];
    NSView *view = host.view; view.translatesAutoresizingMaskIntoConstraints = NO;
    [item.view addSubview:view];
    [NSLayoutConstraint activateConstraints:@[
        [view.leadingAnchor constraintEqualToAnchor:item.view.leadingAnchor],
        [view.trailingAnchor constraintEqualToAnchor:item.view.trailingAnchor],
        [view.topAnchor constraintEqualToAnchor:item.view.topAnchor],
        [view.bottomAnchor constraintEqualToAnchor:item.view.bottomAnchor]
    ]];
    return YES;
}
- (void)recordOfficeTab:(ASCTabView *)tab {
    if ([tab.params[@"fwPreview"] boolValue]) self.previewID = tab.uuid;
}
- (void)replaceCleanPreview {
    ASCTabView *previous = [self.owner.tabsControl tabWithUUID:self.previewID];
    if (!previous) { self.previewID = nil; return; }
    FWDocumentHost *host = self.documents[previous.uuid];
    NSCefView *cef = [self.owner cefViewWithTab:previous];
    if (host.modified || host.busy || [self.closing containsObject:previous.uuid] ||
        [cef.data hasChanges] || [cef isSaveLocked] || [cef checkBuilding]) {
        [self pinTab:previous];
    } else if (host) {
        self.previewID = nil;
        [self.closing addObject:previous.uuid];
        [host closeCleanPreviewWithCompletion:^(BOOL closed) {
            [self.closing removeObject:previous.uuid];
            if (closed && self.documents[previous.uuid] == host) {
                [self.owner.tabsControl removeTab:previous selected:NO animated:NO];
            } else [self pinTab:previous];
        }];
    } else if (![cef checkCloudCryptoNeedBuild]) {
        self.previewID = nil;
        [self.owner.tabsControl removeTab:previous selected:NO animated:NO];
    } else [self pinTab:previous];
}
- (void)pinTab:(ASCTabView *)tab {
    if (!tab) return;
    tab.params[@"fwPreview"] = @NO;
    if ([self.previewID isEqualToString:tab.uuid]) self.previewID = nil;
    [self updateTab:tab];
}
- (void)updateTab:(ASCTabView *)tab {
    if (!tab) return;
    FWDocumentHost *host = self.documents[tab.uuid];
    if (host) {
        if (host.modified) {
            tab.params[@"fwPreview"] = @NO;
            if ([self.previewID isEqualToString:tab.uuid]) self.previewID = nil;
        }
        tab.title = [NSString stringWithFormat:@"%@%@%@", [tab.params[@"fwPreview"] boolValue] ? @"预览 · " : @"",
                     host.documentTitle, host.modified ? @" •" : @""];
        if (host.documentURL) tab.params[@"path"] = host.documentURL.path;
        [self.owner.tabsControl updateTab:tab];
    }
    if (self.owner.tabsControl.selectedTab == tab) [self updateEditorState];
}
- (void)updateEditorState {
    ASCTabView *tab = self.owner.tabsControl.selectedTab;
    FWDocumentHost *host = self.documents[tab.uuid ?: @""];
    self.browser.legacyDocument = host;
    NSCefView *cef = tab && !host ? [self.owner cefViewWithTab:tab] : nil;
    NSString *path = host.documentURL.path ?: cef.data.path ?: tab.params[@"path"];
    NSURL *url = path.length ? [NSURL fileURLWithPath:path] : nil;
    BOOL ready = cef && [self.readyOfficeTabs containsObject:tab.uuid];
    BOOL officeBusy = cef && (!ready || [cef isSaveLocked] || [cef checkBuilding] || [self.saveReturnTabID isEqualToString:tab.uuid]);
    BOOL officeCanSave = ready && [cef.data isViewType:cvwtEditor] && !cef.data.hasError &&
                         ![cef.data closed] && !officeBusy;
    [self.browser updateEditorWithTitle:host.documentTitle ?: tab.title ?: @"文件编辑"
                                   url:url hasDocument:tab != nil
                              modified:host ? host.modified : [cef.data hasChanges]
                                  busy:host ? host.busy : officeBusy
                               canSave:host ? host.canSave : officeCanSave
                             canSaveAs:host ? host.canSaveAs : officeCanSave
                             canExport:host ? host.canExport : officeCanSave];
}
- (void)didSelectTab:(ASCTabView *)tab {
    if (self.saveReturnTabID && ![self.saveReturnTabID isEqualToString:tab.uuid]) [self cancelSaveReturn];
    [self updateEditorState];
    if (tab) [self.browser showEditor];
    else [self.browser hideEditor];
}
- (void)didRemoveTab:(ASCTabView *)tab {
    FWDocumentHost *host = self.documents[tab.uuid];
    host.stateDidChange = nil;
    [host removeFromParentViewController];
    [self.documents removeObjectForKey:tab.uuid];
    [self.closing removeObject:tab.uuid];
    [self.readyOfficeTabs removeObject:tab.uuid];
    if ([self.previewID isEqualToString:tab.uuid]) self.previewID = nil;
}
- (void)requestCloseTab:(ASCTabView *)tab {
    if (self.closingAll) return;
    FWDocumentHost *host = self.documents[tab.uuid];
    if (!host || [self.closing containsObject:tab.uuid]) return;
    [self.closing addObject:tab.uuid];
    [self.owner.tabsControl selectTab:tab];
    [host requestCloseIn:self.browser.currentDirectory completion:^(BOOL closed) {
        [self.closing removeObject:tab.uuid];
        if (closed && self.documents[tab.uuid] == host) [self.owner.tabsControl removeTab:tab animated:NO];
        else [self.owner fwCancelPendingClose];
    }];
}
- (BOOL)canSaveSelectedAs:(BOOL)saveAs { return saveAs ? self.selectedDocument.canSaveAs : self.selectedDocument.canSave; }
- (void)saveSelectedAs:(BOOL)saveAs {
    FWDocumentHost *host = self.selectedDocument;
    [host saveIn:self.browser.currentDirectory saveAs:saveAs completion:^(BOOL success) {
        if (success) [self.browser refreshDirectory];
        [self updateEditorState];
    }];
}
- (void)cancelSaveReturn {
    self.saveReturnRequest = nil;
    self.saveReturnTabID = nil;
}
- (void)saveAndReturnSelected {
    ASCTabView *tab = self.owner.tabsControl.selectedTab;
    FWDocumentHost *host = self.selectedDocument;
    if (host) {
        [host saveIn:self.browser.currentDirectory saveAs:(!host.canSave && host.canSaveAs) completion:^(BOOL success) {
            // 保存失败、目标已切换或等待期间继续输入时，都保留原会话。
            if (success && self.selectedDocument == host && self.owner.tabsControl.selectedTab == tab && !host.modified && !host.busy) {
                // 复用无提示的干净关闭门禁：暂停交互并最终同步 WK，晚到输入必须留在编辑器。
                [host closeCleanPreviewWithCompletion:^(BOOL closed) {
                    BOOL wasSelected = self.owner.tabsControl.selectedTab == tab;
                    if (closed && self.documents[tab.uuid] == host) [self.owner.tabsControl removeTab:tab animated:NO];
                    if (closed && wasSelected) [self.browser hideEditor];
                    [self updateEditorState];
                }];
            }
            [self updateEditorState];
        }];
        return;
    }
    NSCefView *cef = tab ? [self.owner cefViewWithTab:tab] : nil;
    if (!cef || self.saveReturnRequest || ![self.readyOfficeTabs containsObject:tab.uuid] ||
        [cef isSaveLocked] || [cef checkBuilding] || cef.data.hasError || [cef.data closed]) return;
    if (!cef.data.hasChanges && cef.data.path.length && [[NSFileManager defaultManager] fileExistsAtPath:cef.data.path]) {
        [self.browser hideEditor];
        return;
    }
    NSString *request = NSUUID.UUID.UUIDString;
    self.saveReturnRequest = request;
    self.saveReturnTabID = tab.uuid;
    [self updateEditorState];
    [self saveFromButton:nil];
    // 只接受本次保存的完成通知；超时只解除等待，绝不把“发出保存命令”当成保存成功。
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if ([weakSelf.saveReturnRequest isEqualToString:request]) {
            [weakSelf cancelSaveReturn];
            [weakSelf updateEditorState];
        }
    });
}
- (void)finishOfficeSaveReturn:(ASCTabView *)tab request:(NSString *)request deadline:(NSDate *)deadline {
    if (!request || ![self.saveReturnRequest isEqualToString:request]) return;
    NSCefView *cef = [self.owner cefViewWithTab:tab];
    if (!cef || self.owner.tabsControl.selectedTab != tab || !self.browser.hasAnyPreview || self.closingAll ||
        cef.data.hasChanges || cef.data.hasError || [cef.data closed] || deadline.timeIntervalSinceNow <= 0) {
        [self cancelSaveReturn]; [self updateEditorState]; return;
    }
    if ([cef isSaveLocked] || [cef checkBuilding]) {
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            [weakSelf finishOfficeSaveReturn:tab request:request deadline:deadline];
        });
        return;
    }
    [self cancelSaveReturn];
    [self.browser hideEditor];
    [self updateEditorState];
}
- (void)openFromButton:(id)sender { [[FWWorkbenchCoordinator current] openPanel]; }
- (void)saveFromButton:(id)sender { [(AppDelegate *)NSApp.delegate onMenuSave:sender]; }
- (void)saveAsFromButton:(id)sender { [(AppDelegate *)NSApp.delegate onMenuSaveAs:sender]; }
- (void)exportSelected:(id)sender {
    FWWorkbenchCoordinator *coordinator = [FWWorkbenchCoordinator current];
    if (coordinator.selectedDocument) [coordinator.selectedDocument exportIn:coordinator.browser.currentDirectory];
    else [(AppDelegate *)NSApp.delegate onMenuSaveAs:sender];
}
- (void)findSelected:(id)sender { [[FWWorkbenchCoordinator current].selectedDocument find]; }
- (void)undoSelected:(id)sender { [[FWWorkbenchCoordinator current].selectedDocument undo]; }
- (void)redoSelected:(id)sender { [[FWWorkbenchCoordinator current].selectedDocument redo]; }
- (void)pinSelected:(id)sender {
    FWWorkbenchCoordinator *coordinator = [FWWorkbenchCoordinator current];
    [coordinator pinTab:coordinator.owner.tabsControl.selectedTab];
}
- (BOOL)validateMenuItem:(NSMenuItem *)item {
    FWWorkbenchCoordinator *coordinator = [FWWorkbenchCoordinator current];
    if (item.action == @selector(undoSelected:)) return coordinator.selectedDocument.canUndo;
    if (item.action == @selector(redoSelected:)) return coordinator.selectedDocument.canRedo;
    if (item.action == @selector(findSelected:)) return coordinator.selectedDocument.canFind;
    if (item.action == @selector(exportSelected:)) return coordinator.selectedDocument ? coordinator.selectedDocument.canExport : coordinator.owner.tabsControl.selectedTab != nil;
    return coordinator != nil;
}
@end
