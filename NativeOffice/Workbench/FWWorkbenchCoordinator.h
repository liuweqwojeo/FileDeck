#import <Cocoa/Cocoa.h>
@class ASCCommonViewController, ASCTabView, FWDocumentHost;

/// 将浏览页与原生/Office 编辑会话统一在原窗口，保留上游 CEF 保存和退出流程。
@interface FWWorkbenchCoordinator : NSObject <NSMenuItemValidation>
+ (instancetype)installInController:(ASCCommonViewController *)controller;
+ (instancetype)forController:(ASCCommonViewController *)controller;
+ (instancetype)current;
+ (BOOL)isNativeTab:(ASCTabView *)tab;
+ (BOOL)isOfficeURL:(NSURL *)url;
+ (NSURL *)saveDirectoryForOfficeViewID:(int)viewID;
- (BOOL)hasBusyDocuments;
- (BOOL)prepareToCloseApplication:(BOOL)application;
- (BOOL)hasChangesForTab:(ASCTabView *)tab;
- (BOOL)addNativeTab:(ASCTabView *)tab;
- (void)didSelectTab:(ASCTabView *)tab;
- (void)didRemoveTab:(ASCTabView *)tab;
- (void)recordOfficeTab:(ASCTabView *)tab;
- (void)requestCloseTab:(ASCTabView *)tab;
- (BOOL)hasSelectedNativeDocument;
- (BOOL)canSaveSelectedAs:(BOOL)saveAs;
- (void)saveSelectedAs:(BOOL)saveAs;
- (void)openPanel;
- (void)openURL:(NSURL *)url pinned:(BOOL)pinned;
- (void)pinTab:(ASCTabView *)tab;
- (FWDocumentHost *)nativeDocumentForTab:(ASCTabView *)tab;
@end
