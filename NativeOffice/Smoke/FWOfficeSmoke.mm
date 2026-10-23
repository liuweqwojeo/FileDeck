#import "FWOfficeSmoke.h"
#import "ASCCommonViewController.h"
#import "ASCConstants.h"
#import "ASCExternalController.h"
#import "NSString+Extensions.h"
#import "mac_application.h"
#if FW_WORKBENCH_ENABLED
#import "FWWorkbenchCoordinator.h"
#import "FileWorkbenchNative-Swift.h"
#import "AppDelegate.h"
#import <PDFKit/PDFKit.h>
@interface AppDelegate (FWMixedSmokeMenu)
- (IBAction)onMenuSave:(id)sender;
@end
#endif
#include <sys/stat.h>
#include <unistd.h>
#include <cmath>

// 此驱动仅运行在专门启动的验收进程中；保存继续使用上游事件和转换器，不直接生成 Office 文件。
@interface FWOfficeSmoke : NSObject
@property(nonatomic, copy) NSString *directory;
@property(nonatomic, copy) NSString *profile;
@property(nonatomic, copy) NSString *token;
@property(nonatomic, copy) NSString *marker;
@property(nonatomic, copy) NSString *phase;
@property(nonatomic, weak) ASCCommonViewController *controller;
@property(nonatomic, weak) NSCefView *view;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *results;
@property(nonatomic, strong) NSMutableDictionary *current;
@property(nonatomic) NSTimeInterval deadline;
@property(nonatomic) NSTimeInterval nextProbe;
@property(nonatomic) NSInteger index;
@property(nonatomic) NSInteger viewID;
@property(nonatomic) BOOL started;
@property(nonatomic) BOOL finished;
@property(nonatomic) BOOL savePathIssued;
@property(nonatomic) BOOL savedEvent;
@property(nonatomic) BOOL profileVerified;
@property(nonatomic) ino_t directoryInode;
@property(nonatomic) dev_t directoryDevice;
@property(nonatomic) BOOL workbenchRequested;
@property(nonatomic, copy) NSArray *compressionSamples;
@property(nonatomic) NSMutableDictionary *workbenchResult;
#if FW_WORKBENCH_ENABLED
@property(nonatomic, weak) FWBrowserHost *modalBrowser;
@property(nonatomic, weak) NSWindow *modalWindow;
@property(nonatomic, strong) FWDocumentHost *modalDocument;
@property(nonatomic, copy) NSData *modalSavedData;
#endif
+ (instancetype)configuredInstance;
- (void)start:(ASCCommonViewController *)controller;
- (BOOL)handleSave:(NSDictionary *)params;
@end

static NSArray<NSDictionary *> *FWCases(void) {
    return @[@{@"kind": @"word", @"format": @"docx", @"file": @"word.docx"},
             @{@"kind": @"cell", @"format": @"xlsx", @"file": @"cell.xlsx"},
             @{@"kind": @"slide", @"format": @"pptx", @"file": @"slide.pptx"}];
}

static void FWInvalidConfiguration(NSString *reason) {
    // 显式测试环境配置错误时直接拒绝启动，不能回落到真实用户的应用数据目录。
    fprintf(stderr, "FileWorkbench Office smoke configuration error: %s\n", reason.UTF8String);
    exit(78);
}

#if FW_WORKBENCH_ENABLED
// 校验真实视图树，避免旧版“浏览栏与编辑器并列”布局也误报为浏览页面内编辑。
static FWBrowserHost *FWEmbeddedBrowser(ASCCommonViewController *controller) {
    NSWindow *window = controller.view.window;
    if (!window) return nil;
    for (NSViewController *child in controller.childViewControllers) {
        if ([child isKindOfClass:FWBrowserHost.class] && child.view.window == window &&
            [controller.tabView isDescendantOf:child.view]) return (FWBrowserHost *)child;
    }
    return nil;
}

static BOOL FWEditorIsEmbedded(ASCCommonViewController *controller, NSView *editor) {
    FWBrowserHost *browser = FWEmbeddedBrowser(controller);
    return browser && editor.window == browser.view.window &&
        [editor isDescendantOf:controller.tabView];
}

// 旧标签容器已经卸载后，现代预览仍属于原来的浏览器和窗口，不能再依赖 tabView 的祖先关系。
static FWBrowserHost *FWBrowserForWindow(ASCCommonViewController *controller, NSWindow *window) {
    if (!window || controller.view.window != window) return nil;
    for (NSViewController *child in controller.childViewControllers) {
        if ([child isKindOfClass:FWBrowserHost.class] && child.view.window == window) return (FWBrowserHost *)child;
    }
    return nil;
}

// 仅从本次验收主窗口当前附着的 sheet 向下查找，绝不扫描其他窗口或点击全局同名按钮。
static NSButton *FWModalSheetButton(NSView *view, NSString *title) {
    if (!view || view.hidden) return nil;
    if ([view isKindOfClass:NSButton.class]) {
        NSButton *button = (NSButton *)view;
        if (button.enabled && [button.title isEqualToString:title]) return button;
    }
    for (NSView *child in view.subviews) {
        NSButton *button = FWModalSheetButton(child, title);
        if (button) return button;
    }
    return nil;
}
#endif

@implementation FWOfficeSmoke

+ (instancetype)configuredInstance {
    static FWOfficeSmoke *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *environment = NSProcessInfo.processInfo.environment;
        NSString *directory = environment[@"FW_OFFICE_SMOKE_DIR"];
        if (!directory.length) return;
        NSString *canonical = directory.stringByStandardizingPath.stringByResolvingSymlinksInPath;
        struct stat metadata;
        if (![directory isAbsolutePath] || ![directory isEqualToString:canonical] ||
            ![directory.lastPathComponent hasPrefix:@"fw-office-smoke-"] ||
            lstat(directory.fileSystemRepresentation, &metadata) || !S_ISDIR(metadata.st_mode) ||
            metadata.st_uid != geteuid() || (metadata.st_mode & 0777) != 0700) {
            FWInvalidConfiguration(@"测试目录必须为当前用户新建的私有目录，且不能经过符号链接。");
        }
        NSString *requestPath = [directory stringByAppendingPathComponent:@"request.json"];
        struct stat requestMetadata;
        if (lstat(requestPath.fileSystemRepresentation, &requestMetadata) ||
            !S_ISREG(requestMetadata.st_mode) || requestMetadata.st_size > 65536) {
            FWInvalidConfiguration(@"缺少有效的 request.json。");
        }
        NSData *data = [NSData dataWithContentsOfFile:requestPath];
        NSDictionary *request = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSString *token = environment[@"FW_OFFICE_SMOKE_TOKEN"];
        if (![request isKindOfClass:NSDictionary.class] || !token.length ||
            ![request[@"deadlineUnix"] isKindOfClass:NSNumber.class]) {
            FWInvalidConfiguration(@"测试请求必须为 JSON 对象，并提供令牌和截止时间。");
        }
        double deadline = [request[@"deadlineUnix"] doubleValue];
        double now = NSDate.date.timeIntervalSince1970;
        if (![request isKindOfClass:NSDictionary.class] || ![request[@"schemaVersion"] isEqual:@1] ||
            ![[NSUUID alloc] initWithUUIDString:token] || ![token isEqual:request[@"token"]] ||
            ![request[@"marker"] isEqual:[@"文件工作台离线验收-" stringByAppendingString:token]] ||
            !std::isfinite(deadline) || deadline <= now || deadline > now + 1800 ||
            ![request[@"networkPolicy"] isEqual:@"sandbox-exec-deny-network"]) {
            FWInvalidConfiguration(@"请求令牌、唯一中文标记、截止时间或离线策略不匹配。");
        }
        for (NSString *name in @[@"word.docx", @"cell.xlsx", @"slide.pptx", @"mixed.txt", @"mixed.pdf", @"native-result.json", @"profile"]) {
            NSString *path = [directory stringByAppendingPathComponent:name];
            struct stat existing;
            if (lstat(path.fileSystemRepresentation, &existing) == 0 || errno != ENOENT) {
                FWInvalidConfiguration(@"测试目录已经包含输出文件或旧 profile，禁止覆盖。");
            }
        }
        instance = [FWOfficeSmoke new];
        instance.directory = directory;
        instance.profile = [directory stringByAppendingPathComponent:@"profile"];
        instance.token = token;
        instance.marker = request[@"marker"];
        instance.deadline = deadline;
        instance.directoryInode = metadata.st_ino;
        instance.directoryDevice = metadata.st_dev;
        instance.index = -1;
        instance.viewID = -1;
        instance.results = [NSMutableArray array];
        instance.workbenchRequested = [request[@"workbench"] boolValue];
        if (request[@"compressionSamples"]) {
            if (![request[@"compressionSamples"] isKindOfClass:NSArray.class]) {
                FWInvalidConfiguration(@"压缩帮助验收样本必须为数组。");
            }
            instance.compressionSamples = request[@"compressionSamples"];
        }
        instance.workbenchResult = [NSMutableDictionary dictionary];
        instance.phase = @"configured";
        if (mkdir(instance.profile.fileSystemRepresentation, 0700)) {
            FWInvalidConfiguration(@"无法创建隔离 profile。");
        }
    });
    return instance;
}

- (BOOL)directoryUnchanged {
    struct stat value;
    return lstat(self.directory.fileSystemRepresentation, &value) == 0 && S_ISDIR(value.st_mode) &&
        value.st_ino == self.directoryInode && value.st_dev == self.directoryDevice &&
        value.st_uid == geteuid() && (value.st_mode & 0777) == 0700 &&
        [self.directory isEqual:self.directory.stringByResolvingSymlinksInPath];
}

- (void)start:(ASCCommonViewController *)controller {
    if (self.started || self.finished) return;
    self.started = YES;
    self.controller = controller;
    CAscApplicationManager *manager = [NSAscApplicationWorker getAppManager];
    if (!manager || manager->m_oSettings.app_data_path != [self.profile stdwstring]) {
        [self finish:@"ASCHelper.applicationDataPath 的测试隔离未接入，拒绝运行。"];
        return;
    }
    self.profileVerified = YES;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(documentReady:) name:CEFEventNameEditorDocumentReady object:nil];
    [center addObserver:self selector:@selector(editorEvent:) name:CEFEventNameEditorEvent object:nil];
    [center addObserver:self selector:@selector(documentSaved:) name:CEFEventNameSave object:nil];
    __weak FWOfficeSmoke *weakSelf = self;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *timer) {
        [weakSelf tick];
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(0, self.deadline - NSDate.date.timeIntervalSince1970) * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!weakSelf.finished) [weakSelf finish:@"超过验收截止时间。"];
    });
    // common 的 viewDidLoad 尚未完全返回，下一轮主队列再创建第一个编辑器标签。
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf nextCase]; });
}

- (void)nextCase {
    if (self.finished) return;
    self.index++;
    if (self.index >= (NSInteger)FWCases().count) {
#if FW_WORKBENCH_ENABLED
        if (self.workbenchRequested) { [self startModalWorkbench]; return; }
#endif
        [self finish:nil]; return;
    }
    self.current = [FWCases()[self.index] mutableCopy];
    self.current[@"marker"] = self.marker;
    self.viewID = -1;
    self.view = nil;
    self.savePathIssued = NO;
    self.savedEvent = NO;
    self.phase = @"creating";
    [self openCurrent:NO];
}

- (void)openCurrent:(BOOL)reopen {
    NSMutableDictionary *params = [@{@"action": @(reopen ? ASCTabActionOpenLocalFile : ASCTabActionCreateLocalFile),
                                     @"type": self.current[@"kind"], @"active": @YES,
                                     @"fwSmokeToken": self.token, @"fwSmokeIndex": @(self.index),
                                     @"fwSmokeReopen": @(reopen)} mutableCopy];
    if (reopen) params[@"path"] = [self.directory stringByAppendingPathComponent:self.current[@"file"]];
    [NSNotificationCenter.defaultCenter postNotificationName:CEFEventNameCreateTab object:nil userInfo:params];
}

- (void)documentReady:(NSNotification *)notification {
    if (self.finished || ![@[@"creating", @"reopening"] containsObject:self.phase]) return;
    NSInteger viewID = [notification.userInfo[@"viewId"] integerValue];
    ASCTabView *tab = [self.controller tabViewWithId:(int)viewID];
    if (![tab.params[@"fwSmokeToken"] isEqual:self.token] ||
        [tab.params[@"fwSmokeIndex"] integerValue] != self.index ||
        [tab.params[@"fwSmokeReopen"] boolValue] != [self.phase isEqual:@"reopening"]) return;
    self.view = [self.controller cefViewWithTab:tab];
    self.viewID = viewID;
    if (!self.view) { [self finish:@"文档就绪但缺少 NSCefView。"]; return; }
    if ([self.phase isEqual:@"creating"]) {
        self.current[@"created"] = @YES;
        self.phase = @"inserting";
    } else {
        self.current[@"reopened"] = @YES;
        self.phase = @"verifying-reopen";
    }
    self.nextProbe = 0;
    [self tick];
}

- (void)executeProbe {
    CAscApplicationManager *manager = [NSAscApplicationWorker getAppManager];
    CCefView *cef = manager ? manager->GetViewById((int)self.viewID) : nullptr;
    if (!cef) { [self finish:@"测试编辑器的 CEF 视图已经消失。"]; return; }
    NSDictionary *config = @{@"token": self.token, @"marker": self.marker,
                             @"format": self.current[@"format"], @"deadline": @(self.deadline * 1000),
                             @"compressed": @(self.compressionSamples != nil),
                             @"samples": [self.current[@"format"] isEqual:@"docx"] ? (self.compressionSamples ?: @[]) : @[],
                             @"reopen": @([self.phase isEqual:@"verifying-reopen"])};
    NSData *json = [NSJSONSerialization dataWithJSONObject:config options:0 error:nil];
    NSString *jsonText = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    // 使用固定 SDK 中导出的 InputText 和查找 API。输入经过真实编辑器输入上下文，不写 OOXML 模板。
    // 它验证中文文本链路，但不代替系统输入法候选、组合输入和键盘焦点的人工验收。
    const char *probe = R"FWJS(
(function(c) {
  var a = window.Asc && window.Asc.editor;
  if (!a || !window.AscDesktopEditor || !window.AscCommon) return;
  var key = c.token + ':' + c.format + ':' + c.reopen;
  window.__fwOfficeSmoke = window.__fwOfficeSmoke || {};
  if (window.__fwOfficeSmoke[key]) return;
  window.__fwOfficeSmoke[key] = true;
  var done = false;
  function report(stage, detail) {
    if (done) return;
    done = true;
    window.AscDesktopEditor.execCommand('editor:event', JSON.stringify({
      action: 'fw:office-smoke', token: c.token, format: c.format,
      stage: stage, detail: detail || ''
    }));
  }
  function containsMarker() {
    if (c.format === 'xlsx') {
      a.asc_closeCellEditor();
      var o = new Asc.asc_CFindOptions();
      o.asc_setFindWhat(c.marker);
      o.asc_setScanForward(true);
      o.asc_setIsMatchCase(true);
      o.asc_setIsWholeCell(false);
      o.asc_setScanOnOnlySheet(Asc.c_oAscSearchBy.Workbook);
      o.asc_setScanByRows(true);
      o.asc_setLookIn(Asc.c_oAscFindLookIn.Value);
      return a.asc_findText(o) > 0;
    }
    var o = new AscCommon.CSearchSettings();
    o.put_Text(c.marker);
    o.put_MatchCase(true);
    o.put_WholeWords(false);
    return a.asc_findText(o, true) > 0;
  }
  function check() {
    if (done) return;
    try {
      if (containsMarker()) { report(c.reopen ? 'verified' : 'inserted'); return; }
      if (Date.now() >= c.deadline) { report('error', 'SDK 查找未找到中文标记。'); return; }
      setTimeout(check, 250);
    } catch(e) { report('error', String(e && e.stack || e)); }
  }
  function loadBytes(sample) {
    return new Promise(function(resolve, reject) {
      AscDesktopEditor.execCommand('editor:event', JSON.stringify({action:'fw:office-smoke',
        token:c.token, format:c.format, stage:'resources-progress', detail:sample.url}));
      var xhr = new XMLHttpRequest();
      xhr.open('GET', sample.url + '?filedeck-smoke=1', true);
      xhr.responseType = 'arraybuffer';
      xhr.timeout = 15000;
      xhr.onload = async function() {
        try {
          if (xhr.status !== 200 || !xhr.response || xhr.response.byteLength !== sample.bytes)
            throw Error('压缩帮助响应不完整: ' + sample.url + ' status=' + xhr.status);
          var digest = await crypto.subtle.digest('SHA-256', xhr.response);
          var hex = Array.from(new Uint8Array(digest), function(n) { return n.toString(16).padStart(2, '0'); }).join('');
          if (hex !== sample.sha256) throw Error('压缩帮助响应摘要不一致: ' + sample.url);
          resolve();
        } catch(e) { reject(e); }
      };
      xhr.onerror = function() { reject(Error('压缩帮助读取失败: ' + sample.url)); };
      xhr.ontimeout = function() { reject(Error('压缩帮助读取超时: ' + sample.url)); };
      xhr.send();
    });
  }
  function checkSpell() {
    if (c.format !== 'docx') return Promise.resolve();
    return new Promise(function(resolve, reject) {
      var previous = window.asc_nativeOnSpellCheck;
      var timeout = setTimeout(function() {
        window.asc_nativeOnSpellCheck = previous;
        reject(Error('压缩字典原生回调超时。'));
      }, 15000);
      window.asc_nativeOnSpellCheck = function(response) {
        if (!response || response.fwToken !== c.token) { if (previous) previous(response); return; }
        clearTimeout(timeout);
        window.asc_nativeOnSpellCheck = previous;
        if (JSON.stringify(response.usrCorrect) !== '[true,false,false,false,false,false]')
          reject(Error('压缩字典拼写结果异常: ' + JSON.stringify(response)));
        else resolve();
      };
      // 无词典时上游会把未知单词当正确；五种语言的错词能发现枚举静默失败。
      AscDesktopEditor.SpellCheck(JSON.stringify({type:'spell', fwToken:c.token,
        usrWords:['hello','qzxqzxqzx','qzxqzxqzx','qzxqzxqzx','qzxqzxqzx','qzxqzxqzx'],
        usrLang:[1033,1033,1036,1031,1049,1025]}));
    });
  }
  function checkHelpPanel() {
    return new Promise(function(resolve, reject) {
      var page = c.format === 'xlsx' ? 'en/Functions/sum.htm' : 'en/ProgramInterface/ProgramInterface.htm';
      var url = new URL('resources/help/' + page, location.href).href;
      var deadline = Date.now() + 30000;
      var opened = false;
      function inspect() {
        try {
          var frame = document.querySelector('#id-help-frame iframe');
          var doc = frame && frame.contentDocument;
          var app = window.DE || window.SSE || window.PE;
          var left = app && app.getController('LeftMenu').getView('LeftMenu');
          var help = left && left.menuFile.panels && left.menuFile.panels.help;
          // 文档 SDK 就绪早于菜单脚本；按真实可点击条件打开，避免测试抢在菜单初始化前。
          var ready = Common.Controllers.LaunchController.isScriptLoaded() &&
            left && left.menuFile.mode && left.menuFile.mode.canHelp;
          if (!opened && ready) { opened = true; window.open(url, '_blank'); }
          if (frame && frame.src === url && doc && doc.readyState === 'complete' &&
              doc.body && doc.body.innerText.length > 30 && frame.offsetWidth > 0 &&
              help && help.viewHelpPicker.store.length > 0 &&
              Array.from(doc.images).every(function(image) { return image.complete && image.naturalWidth > 0; })) {
            left.menuFile.hide();
            resolve(); return;
          }
          if (Date.now() >= deadline) throw Error('压缩帮助面板未完成显示: ' + url +
            ' ready=' + ready + ' opened=' + opened +
            ' actual=' + (frame && frame.src) + ' text=' + (doc && doc.body && doc.body.innerText.slice(0, 100)));
          setTimeout(inspect, 200);
        } catch(e) { reject(e); }
      }
      setTimeout(inspect, 200);
    });
  }
  async function run() {
    if (c.compressed && !c.reopen) {
      for (var sample of c.samples) await loadBytes(sample);
      // 上游本地 fetch 用 XHR.onerror 选择默认语言；404 的成功回调会破坏此回退。
      await new Promise(function(resolve, reject) {
        var xhr = new XMLHttpRequest();
        xhr.open('GET', new URL('resources/help/zz-filedeck-missing/Contents.json', location.href).href);
        xhr.timeout = 10000;
        xhr.onload = function() { reject(Error('缺失帮助未保留原本 file URL 的失败语义。')); };
        xhr.onerror = resolve;
        xhr.ontimeout = function() { reject(Error('缺失帮助请求超时。')); };
        xhr.send();
      });
      await checkSpell();
      await checkHelpPanel();
      AscDesktopEditor.execCommand('editor:event', JSON.stringify({action:'fw:office-smoke',
        token:c.token, format:c.format, stage:'resources-verified'}));
    }
    if (!c.reopen) {
      if (typeof a.pluginMethod_InputText !== 'function') throw Error('缺少导出的 pluginMethod_InputText。');
      if (c.format === 'pptx') a.AddSlide(0);
      a.pluginMethod_InputText(c.marker);
    }
    setTimeout(check, 500);
  }
  run().catch(function(e) { report('error', String(e && e.stack || e)); });
})(
)FWJS";
    std::string script(probe);
    script += jsonText.UTF8String;
    script += ");";
    cef->ExecuteInAllFrames(script, true);
}

- (void)editorEvent:(NSNotification *)notification {
    if (self.finished || [notification.userInfo[@"viewId"] integerValue] != self.viewID) return;
    NSDictionary *event = notification.userInfo[@"data"];
    if (![event isKindOfClass:NSDictionary.class] || ![event[@"action"] isEqual:@"fw:office-smoke"] ||
        ![event[@"token"] isEqual:self.token] || ![event[@"format"] isEqual:self.current[@"format"]]) return;
    if ([event[@"stage"] isEqual:@"error"]) { [self finish:event[@"detail"] ?: @"编辑器脚本失败。"]; return; }
    if ([event[@"stage"] isEqual:@"resources-verified"]) {
        self.current[@"compressedResourcesVerified"] = @YES;
        return;
    }
    if ([event[@"stage"] isEqual:@"resources-progress"]) {
        self.current[@"resourceProgress"] = event[@"detail"] ?: @"";
        fprintf(stderr, "Compressed resource probe: %s\n", [event[@"detail"] UTF8String]);
        return;
    }
    if ([self.phase isEqual:@"inserting"] && [event[@"stage"] isEqual:@"inserted"]) {
        self.phase = @"waiting-dirty";
    } else if ([self.phase isEqual:@"verifying-reopen"] && [event[@"stage"] isEqual:@"verified"]) {
        self.current[@"verifiedInEditor"] = @YES;
        self.phase = @"closing-reopened";
    }
}

- (BOOL)handleSave:(NSDictionary *)params {
    if (self.finished || self.viewID < 0 || [params[@"viewId"] integerValue] != self.viewID) return NO;
    if (![self.phase isEqual:@"saving"] || self.savePathIssued || ![self directoryUnchanged]) {
        [self cancelSave:params];
        [self finish:@"出现重复保存请求、异常阶段或测试目录变化。"]; return YES;
    }
    NSString *path = [self.directory stringByAppendingPathComponent:self.current[@"file"]];
    struct stat existing;
    if (lstat(path.fileSystemRepresentation, &existing) == 0 || errno != ENOENT) {
        [self cancelSave:params]; [self finish:@"输出目标已存在，禁止覆盖。"]; return YES;
    }
    NSNumber *fileType = nil;
    for (NSDictionary *format in params[@"supportedFormats"]) {
        if ([format[@"extension"] isEqual:self.current[@"format"]]) { fileType = format[@"type"]; break; }
    }
    if (!fileType) { [self cancelSave:params]; [self finish:@"上游保存对话框没有提供目标 OOXML 格式。"]; return YES; }
    self.savePathIssued = YES;
    NSEditorApi::CAscLocalSaveFileDialog *data = new NSEditorApi::CAscLocalSaveFileDialog();
    data->put_Id((int)self.viewID);
    data->put_Path([path stdwstring]);
    data->put_FileType(fileType.intValue);
    NSEditorApi::CAscMenuEvent *event = new NSEditorApi::CAscMenuEvent(ASC_MENU_EVENT_TYPE_CEF_LOCALFILE_SAVE_PATH);
    event->m_pData = data;
    [NSAscApplicationWorker getAppManager]->Apply(event);
    return YES;
}

- (void)cancelSave:(NSDictionary *)params {
    NSEditorApi::CAscLocalSaveFileDialog *data = new NSEditorApi::CAscLocalSaveFileDialog();
    data->put_Id([params[@"viewId"] intValue]);
    data->put_Path(L"");
    NSEditorApi::CAscMenuEvent *event = new NSEditorApi::CAscMenuEvent(ASC_MENU_EVENT_TYPE_CEF_LOCALFILE_SAVE_PATH);
    event->m_pData = data;
    [NSAscApplicationWorker getAppManager]->Apply(event);
}

- (void)documentSaved:(NSNotification *)notification {
    if (self.finished || ![self.phase isEqual:@"saving"] ||
        [notification.userInfo[@"viewId"] integerValue] != self.viewID) return;
    if ([notification.userInfo[@"cancel"] boolValue]) { [self finish:@"上游取消或未完成保存。"]; return; }
    self.savedEvent = YES;
}

- (BOOL)closeCurrent {
    ASCTabView *tab = [self.controller tabViewWithId:(int)self.viewID];
    if (!tab || ![tab.params[@"fwSmokeToken"] isEqual:self.token] || self.view.data.hasChanges || self.view.isSaveLocked) return NO;
    id<ASCTabsControlDelegate> delegate = self.controller.tabsControl.delegate;
    if ([delegate respondsToSelector:@selector(tabs:willRemovedTab:)] &&
        ![delegate tabs:self.controller.tabsControl willRemovedTab:tab]) return NO;
    [self.controller.tabsControl removeTab:tab animated:NO];
    BOOL closed = [self.controller tabViewWithId:(int)self.viewID] == nil;
    self.view = nil;
    self.viewID = -1;
    return closed;
}

- (void)tick {
    if (self.finished) return;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (now >= self.deadline) { [self finish:@"超过验收截止时间。"]; return; }
    if (![self directoryUnchanged]) { [self finish:@"验收目录已被替换或权限发生变化。"]; return; }
#if FW_WORKBENCH_ENABLED
    if ([self.phase hasPrefix:@"mixed-"]) { [self tickMixedWorkbench]; return; }
    if ([self.phase hasPrefix:@"modal-"]) { [self tickModalWorkbench]; return; }
#endif
    if ([@[@"inserting", @"verifying-reopen"] containsObject:self.phase] && now >= self.nextProbe) {
        self.nextProbe = now + 1;
        [self executeProbe];
    } else if ([self.phase isEqual:@"waiting-dirty"] && self.view.data.hasChanges) {
        self.current[@"edited"] = @YES;
#if FW_WORKBENCH_ENABLED
        if (self.index == 0 && self.workbenchRequested) { [self startMixedWorkbench]; return; }
#else
        if (self.workbenchRequested) { [self finish:@"此应用没有编入工作台，不能跳过混合标签验收。"]; return; }
#endif
        self.phase = @"saving";
        // 与菜单“保存”使用完全相同的事件，不能绕过上游的本地转换和恢复状态。
        [self.view apply:new NSEditorApi::CAscMenuEvent(ASC_MENU_EVENT_TYPE_CEF_SAVE)];
    } else if ([self.phase isEqual:@"saving"] && self.savedEvent && self.savePathIssued &&
               !self.view.data.hasChanges && !self.view.isSaveLocked) {
        NSString *path = [self.directory stringByAppendingPathComponent:self.current[@"file"]];
        struct stat output;
        if (lstat(path.fileSystemRepresentation, &output) != 0) return;
        if (!S_ISREG(output.st_mode) || output.st_size <= 0) { [self finish:@"上游保存结果不是有效普通文件。"]; return; }
        self.current[@"saved"] = @YES;
        if (![self closeCurrent]) { [self finish:@"保存后的标签未能正常关闭。"]; return; }
        self.current[@"closed"] = @YES;
        self.phase = @"reopening";
        [self openCurrent:YES];
    } else if ([self.phase isEqual:@"closing-reopened"]) {
        if (![self closeCurrent]) { [self finish:@"重开验证后标签仍为修改状态，或拒绝关闭。"]; return; }
        self.current[@"closedAfterReopen"] = @YES;
        [self.results addObject:[self.current copy]];
        [self nextCase];
    }
}

#if FW_WORKBENCH_ENABLED
/// 在真实 Office 文档仍有未保存内容时切换文本/PDF，再通过应用菜单路由保存。
/// 文件只写入已验证的新建私有验收目录，不访问用户最近文件。
- (void)startMixedWorkbench {
    if (!FWEditorIsEmbedded(self.controller, self.view)) {
        [self finish:@"Office 编辑器没有嵌入当前浏览页面的同一窗口。"]; return;
    }
    self.workbenchResult[@"browserEmbedded"] = @YES;
    NSError *error;
    NSData *data = [@"初始内容\r\n" dataUsingEncoding:NSUTF8StringEncoding];
    if (![data writeToFile:[self.directory stringByAppendingPathComponent:@"mixed.txt"]
                  options:NSDataWritingWithoutOverwriting error:&error]) {
        [self finish:error.localizedDescription ?: @"无法创建混合标签样本。"]; return;
    }
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(400, 300)];
    [image lockFocus]; [[NSColor whiteColor] setFill]; NSRectFill(NSMakeRect(0, 0, 400, 300));
    [self.marker drawAtPoint:NSMakePoint(20, 140) withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:12]}];
    [image unlockFocus];
    PDFDocument *pdf = [PDFDocument new];
    [pdf insertPage:[[PDFPage alloc] initWithImage:image] atIndex:0];
    if (![pdf.dataRepresentation writeToFile:[self.directory stringByAppendingPathComponent:@"mixed.pdf"]
                                    options:NSDataWritingWithoutOverwriting error:&error]) {
        [self finish:error.localizedDescription ?: @"无法创建 PDF 标签样本。"]; return;
    }
    self.phase = @"mixed-text-loading";
    [[FWWorkbenchCoordinator forController:self.controller] openURL:[NSURL fileURLWithPath:[self.directory stringByAppendingPathComponent:@"mixed.txt"]] pinned:YES];
}

- (void)tickMixedWorkbench {
    FWWorkbenchCoordinator *coordinator = [FWWorkbenchCoordinator forController:self.controller];
    ASCTabView *officeTab = [self.controller tabViewWithId:(int)self.viewID];
    NSString *textPath = [self.directory stringByAppendingPathComponent:@"mixed.txt"];
    ASCTabView *textTab = [self.controller tabWithParam:@"path" value:textPath];
    FWDocumentHost *textHost = [coordinator nativeDocumentForTab:textTab];
    if (!coordinator || !officeTab || !self.view.data.hasChanges) {
        [self finish:@"切换原生标签后 Office 会话或未保存状态丢失。"]; return;
    }
    if ([self.phase isEqual:@"mixed-text-loading"]) {
        if (!textHost || textHost.busy) return;
        if (self.controller.tabsControl.selectedTab != textTab || [self.controller cefViewWithTab:textTab]) {
            [self finish:@"文本标签没有独立选中，或被误识别为 CEF。"]; return;
        }
        if (!FWEditorIsEmbedded(self.controller, textHost.view)) {
            [self finish:@"真实文本编辑器没有保留在浏览页面内。"]; return;
        }
        textTab.params[@"fwSmokeToken"] = self.token;
        self.phase = @"mixed-text-editing";
        [textHost smokeReplaceText:[self.marker stringByAppendingString:@"\r\n"] completion:^(NSError *error) {
            if (self.finished) return;
            if (error || !textHost.modified) { [self finish:error.localizedDescription ?: @"文本真实编辑未产生脏状态。"]; return; }
            self.workbenchResult[@"textEditedInWebKit"] = @YES;
            self.phase = @"mixed-text-targeting";
            // 菜单命令归属前台窗口；激活和成为 key window 的通知可能跨一个事件循环。
            [NSApp activateIgnoringOtherApps:YES];
            [self.controller.view.window makeKeyAndOrderFront:nil];
            self.workbenchResult[@"menuTargetRequestedAt"] = @(NSDate.date.timeIntervalSince1970);
        }];
    } else if ([self.phase isEqual:@"mixed-text-targeting"]) {
        if ([FWWorkbenchCoordinator current] != coordinator) {
            if (NSDate.date.timeIntervalSince1970 - [self.workbenchResult[@"menuTargetRequestedAt"] doubleValue] > 3) {
                [self finish:[NSString stringWithFormat:@"菜单目标未建立：active=%d，key=%@，main=%@，owner=%@，ownerController=%@。",
                              NSApp.active, NSApp.keyWindow, NSApp.mainWindow, self.controller.view.window,
                              self.controller.view.window.contentViewController]];
            }
            return;
        }
        self.workbenchResult[@"nativeMenuTargetMatched"] = @YES;
        self.phase = @"mixed-text-saving";
        [(AppDelegate *)NSApp.delegate onMenuSave:nil];
        // 保存面板/异步写入必须捕获发起的文档，此时切回 Office 不能改变目标。
        [self.controller.tabsControl selectTab:officeTab];
    } else if ([self.phase isEqual:@"mixed-text-saving"]) {
        if (textHost.busy) return;
        NSString *saved = [NSString stringWithContentsOfFile:textPath encoding:NSUTF8StringEncoding error:nil];
        if (textHost.modified || ![saved isEqual:[self.marker stringByAppendingString:@"\r\n"]] ||
            self.controller.tabsControl.selectedTab != officeTab) {
            [self finish:[NSString stringWithFormat:@"菜单保存失败：窗口目标=%@，未保存=%d，内容匹配=%d，选中Office=%d。",
                          self.workbenchResult[@"nativeMenuTargetMatched"], textHost.modified,
                          [saved isEqual:[self.marker stringByAppendingString:@"\r\n"]],
                          self.controller.tabsControl.selectedTab == officeTab]]; return;
        }
        if (!FWEditorIsEmbedded(self.controller, self.view)) {
            [self finish:@"切回 Office 后编辑器离开了浏览页面或当前窗口。"]; return;
        }
        self.workbenchResult[@"editorStillInBrowserWindow"] = @YES;
        self.workbenchResult[@"nativeSaveRoutedWhileSwitching"] = @YES;
        self.phase = @"mixed-text-closing";
        [coordinator requestCloseTab:textTab];
    } else if ([self.phase isEqual:@"mixed-text-closing"]) {
        if (textTab) return;
        self.workbenchResult[@"nativeCloseVerified"] = @YES;
        self.phase = @"mixed-pdf-loading";
        [coordinator openURL:[NSURL fileURLWithPath:[self.directory stringByAppendingPathComponent:@"mixed.pdf"]] pinned:YES];
    } else if ([self.phase isEqual:@"mixed-pdf-loading"]) {
        ASCTabView *pdfTab = [self.controller tabWithParam:@"path" value:[self.directory stringByAppendingPathComponent:@"mixed.pdf"]];
        FWDocumentHost *pdfHost = [coordinator nativeDocumentForTab:pdfTab];
        if (!pdfHost || pdfHost.busy) return;
        pdfTab.params[@"fwSmokeToken"] = self.token;
        if ([self.controller cefViewWithTab:pdfTab] || self.controller.tabsControl.selectedTab != pdfTab) {
            [self finish:@"PDF 未进入独立原生标签。"]; return;
        }
        if (!FWEditorIsEmbedded(self.controller, pdfHost.view)) {
            [self finish:@"PDF 编辑器没有保留在浏览页面内。"]; return;
        }
        self.workbenchResult[@"pdfNativeTabVerified"] = @YES;
        self.phase = @"mixed-pdf-closing";
        [coordinator requestCloseTab:pdfTab];
    } else if ([self.phase isEqual:@"mixed-pdf-closing"]) {
        if ([self.controller tabWithParam:@"path" value:[self.directory stringByAppendingPathComponent:@"mixed.pdf"]]) return;
        [self.controller.tabsControl selectTab:officeTab];
        self.workbenchResult[@"officeRetainedUnsavedChanges"] = @YES;
        self.workbenchResult[@"passed"] = @YES;
        self.phase = @"saving";
        [(AppDelegate *)NSApp.delegate onMenuSave:nil];
    }
}

/// 全部 Office 创建/保存/重开及原生混合标签验证完成后，再验收生产弹窗的统一关闭入口。
/// 样本仍使用本次私有目录内已真实保存的 mixed.txt；后续只编辑内存草稿并验证放弃不会落盘。
- (void)startModalWorkbench {
    NSWindow *window = self.controller.view.window;
    FWBrowserHost *browser = FWBrowserForWindow(self.controller, window);
    NSString *path = [self.directory stringByAppendingPathComponent:@"mixed.txt"];
    struct stat metadata;
    NSData *expected = [[self.marker stringByAppendingString:@"\r\n"] dataUsingEncoding:NSUTF8StringEncoding];
    NSData *saved = [NSData dataWithContentsOfFile:path];
    if (!self.workbenchRequested || self.results.count != FWCases().count ||
        ![self.workbenchResult[@"passed"] boolValue] || ![self directoryUnchanged] ||
        !browser || !window.visible || window.attachedSheet ||
        lstat(path.fileSystemRepresentation, &metadata) || !S_ISREG(metadata.st_mode) ||
        ![path isEqualToString:path.stringByResolvingSymlinksInPath] || ![saved isEqualToData:expected]) {
        [self finish:@"现代弹窗验收前置条件不满足，或混合文本样本不再是本次保存的文件。"]; return;
    }
    self.modalBrowser = browser;
    self.modalWindow = window;
    self.modalSavedData = saved;
    self.phase = @"modal-wait-legacy";
    [browser hideEditor];
}

- (BOOL)modalDraftIsRetained {
    return self.modalWindow.visible && self.modalBrowser.hasFilePreview &&
        self.modalDocument && self.modalBrowser.previewDocument == self.modalDocument &&
        self.modalDocument.view.window == self.modalWindow && self.modalDocument.modified;
}

- (void)tickModalWorkbench {
    FWBrowserHost *browser = self.modalBrowser;
    NSWindow *window = self.modalWindow;
    if (!window.visible || !browser || FWBrowserForWindow(self.controller, window) != browser) {
        [self finish:@"现代弹窗验收过程中原工作台或主窗口已丢失。"]; return;
    }
    if ([self.phase isEqual:@"modal-wait-legacy"]) {
        if (browser.hasAnyPreview) return;
        self.phase = @"modal-loading";
        [browser openPreviewURL:[NSURL fileURLWithPath:[self.directory stringByAppendingPathComponent:@"mixed.txt"]]
                         source:@"smoke"];
    } else if ([self.phase isEqual:@"modal-loading"]) {
        FWDocumentHost *host = browser.previewDocument;
        if (!host || !host.canBeginEditing) return;
        if (!browser.hasFilePreview || host.view.window != window || host.modified) {
            [self finish:@"文本预览未以未修改的独立弹窗进入原工作台窗口。"]; return;
        }
        self.modalDocument = host;
        self.phase = @"modal-enter-edit";
        [host beginEditing];
    } else if ([self.phase isEqual:@"modal-enter-edit"]) {
        FWDocumentHost *host = self.modalDocument;
        if (host.busy || !host.canSave) return;
        self.phase = @"modal-editing";
        [host smokeReplaceText:[self.marker stringByAppendingString:@"\r\nmodal draft\r\n"] completion:^(NSError *error) {
            if (self.finished) return;
            if (![self.phase isEqual:@"modal-editing"] || error || ![self modalDraftIsRetained]) {
                [self finish:error.localizedDescription ?: @"现代弹窗真实编辑未保留同一文档的未保存状态。"]; return;
            }
            // 先迁移阶段再发起真正的窗口关闭，防止同步回调或定时器重复提交关闭。
            self.phase = @"modal-window-sheet";
            [self.modalWindow performClose:nil];
        }];
    } else if ([self.phase isEqual:@"modal-window-sheet"] || [self.phase isEqual:@"modal-quit-sheet"]) {
        NSWindow *sheet = window.attachedSheet;
        if (!sheet) return;
        if (![self modalDraftIsRetained]) {
            [self finish:@"关闭确认出现前，弹窗中的未保存草稿已丢失。"]; return;
        }
        NSButton *cancel = FWModalSheetButton(sheet.contentView, @"取消");
        if (!cancel) return;
        self.phase = [self.phase isEqual:@"modal-window-sheet"] ? @"modal-window-cancelled" : @"modal-quit-cancelled";
        [cancel performClick:nil];
    } else if ([self.phase isEqual:@"modal-window-cancelled"] || [self.phase isEqual:@"modal-quit-cancelled"]) {
        if (window.attachedSheet || self.modalDocument.busy) return;
        if (![self modalDraftIsRetained]) {
            [self finish:@"取消窗口关闭或应用退出后，主窗口、同一编辑器或未保存草稿没有保留。"]; return;
        }
        if ([self.phase isEqual:@"modal-window-cancelled"]) {
            self.workbenchResult[@"modalWindowCloseProtected"] = @YES;
            self.phase = @"modal-quit-sheet";
            [NSApp terminate:nil];
        } else {
            self.workbenchResult[@"modalQuitProtected"] = @YES;
            self.phase = @"modal-discard-sheet";
            [browser requestClosePreviewWithCompletion:^(BOOL closed) {
                if (self.finished) return;
                NSData *saved = [NSData dataWithContentsOfFile:[self.directory stringByAppendingPathComponent:@"mixed.txt"]];
                if (![self.phase isEqual:@"modal-discard-waiting"] || !closed ||
                    self.modalBrowser.hasAnyPreview || self.modalBrowser.hasFilePreview || !self.modalWindow.visible ||
                    ![self directoryUnchanged] || ![saved isEqualToData:self.modalSavedData]) {
                    [self finish:@"不保存关闭未正常完成，或 mixed.txt 的原始标记/CRLF 字节发生变化。"]; return;
                }
                self.workbenchResult[@"modalDiscardClosed"] = @YES;
                self.phase = @"modal-completed";
                [self finish:nil];
            }];
        }
    } else if ([self.phase isEqual:@"modal-discard-sheet"]) {
        NSWindow *sheet = window.attachedSheet;
        if (!sheet) return;
        if (![self modalDraftIsRetained]) {
            [self finish:@"用户选择不保存之前，弹窗草稿已被关闭。"]; return;
        }
        NSButton *discard = FWModalSheetButton(sheet.contentView, @"不保存");
        if (!discard) return;
        self.phase = @"modal-discard-waiting";
        [discard performClick:nil];
    }
}
#endif

- (void)finish:(NSString *)error {
    if (self.finished) return;
    self.finished = YES;
    [self.timer invalidate];
    [NSNotificationCenter.defaultCenter removeObserver:self];
    NSMutableDictionary *result = [@{@"schemaVersion": @1, @"token": self.token,
                                     @"status": error ? @"failed" : @"passed", @"phase": self.phase,
                                     @"cases": self.results, @"finishedUnix": @(NSDate.date.timeIntervalSince1970),
                                     @"profileIsolated": @(self.profileVerified),
                                     @"inputMethod": @"SDK pluginMethod_InputText; system IME not tested"} mutableCopy];
    if (self.workbenchRequested) result[@"workbench"] = self.workbenchResult;
    if (error) { result[@"error"] = error; if (self.current) result[@"currentCase"] = self.current; }
    NSData *data = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];
    NSError *writeError;
    if (![self directoryUnchanged] || ![data writeToFile:[self.directory stringByAppendingPathComponent:@"native-result.json"]
                                              options:NSDataWritingWithoutOverwriting error:&writeError]) {
        fprintf(stderr, "Cannot write native smoke result: %s\n", (writeError.localizedDescription ?: @"directory changed").UTF8String);
    }
    // 失败时仅丢弃带本次令牌的临时标签；不对其他标签执行保存、关闭或修改。
    if (error) {
        for (ASCTabView *tab in [self.controller.tabsControl.tabs copy]) {
            if ([tab.params[@"fwSmokeToken"] isEqual:self.token]) [self.controller.tabsControl removeTab:tab animated:NO];
        }
    }
    dispatch_async(dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
}
@end

/// 上游 delegate 为 assign，包装器及原 delegate 都须保活；其他可选回调透明转发。
@interface FWOfficeSmokeDelegate : NSObject <ASCExternalDelegate>
@property(nonatomic, strong) id<ASCExternalDelegate> downstream;
@end

@implementation FWOfficeSmokeDelegate
- (BOOL)respondsToSelector:(SEL)selector {
    return [super respondsToSelector:selector] || [self.downstream respondsToSelector:selector];
}
- (id)forwardingTargetForSelector:(SEL)selector {
    if ([self.downstream respondsToSelector:selector]) return self.downstream;
    return [super forwardingTargetForSelector:selector];
}
- (void)onCommonViewDidLoad:(id)controller {
    if ([self.downstream respondsToSelector:@selector(onCommonViewDidLoad:)]) {
        [self.downstream onCommonViewDidLoad:controller];
    }
    FWOfficeSmokeStart(controller);
}
@end

NSString *FWOfficeSmokeApplicationDataPath(void) {
    return [FWOfficeSmoke configuredInstance].profile;
}

void FWOfficeSmokeInstallDelegate(void) {
    if (![FWOfficeSmoke configuredInstance]) return;
    static FWOfficeSmokeDelegate *delegate;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        delegate = [FWOfficeSmokeDelegate new];
        delegate.downstream = ASCExternalController.shared.delegate;
        ASCExternalController.shared.delegate = delegate;
    });
}

void FWOfficeSmokeStart(id commonController) {
    FWOfficeSmoke *smoke = [FWOfficeSmoke configuredInstance];
    if (!smoke) return;
    if (![commonController isKindOfClass:ASCCommonViewController.class]) return;
    NSCAssert(NSThread.isMainThread, @"Office smoke 必须在主线程启动。");
    [smoke start:commonController];
}

BOOL FWOfficeSmokeHandleSaveParams(NSDictionary *params) {
    return [[FWOfficeSmoke configuredInstance] handleSave:params];
}
