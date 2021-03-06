//
//  GZWKWebViewController.m
//  gezilicai
//
//  Created by gslicai on 16/6/28.
//  Copyright © 2016年 yuexue. All rights reserved.
//

#import "GZWKWebViewController.h"
#import <WebKit/WebKit.h>
#import "WKWebView+JavascriptInterface.h"
#import "JavascriptInterface.h"
#import "Masonry.h"
#import <objc/runtime.h>
#import "GZBaseWebViewController+DisturbRequest.h"
#import "AppTools.h"
#import "WkSharedProcessPool.h"

#define FETCH_TITLE_USE_KVO

@interface GZWKWebViewController()<WKUIDelegate,WKNavigationDelegate,WKScriptMessageHandler,UIScrollViewDelegate,WKHTTPCookieStoreObserver>{
    WKWebViewConfiguration *_webViewConfiguration;
    UIProgressView *_progressBar;
    dispatch_source_t _progressTimer;
}

@property (nonatomic,strong) WKWebView* webView;
@property (nonatomic,strong) NSMutableArray *wekKitCookies;

@end

@implementation GZWKWebViewController

+ (instancetype)newInstanceWithUrl:(NSString *)url andDelegate:(NSObject<GZWebManagerDelegate> *)delegate{
    GZWKWebViewController* instance = [[GZWKWebViewController alloc]init];
    instance.url = url;
    instance.delegate = delegate;
    return instance;
}

- (void)viewDidLoad{
    [super viewDidLoad];
    self.webviewType = WK_WebView;
    
    [self webViewInit];
    if (!self.disableRefresh) {
        __unsafe_unretained typeof(self) weakSelf = self;
        [self setRefreshHeader:nil iforBlock:^{
            [weakSelf reloadURL];
        }];
    }
    if (!self.disableProgress) {
        [self addProgressBar];
    }
    
    [self openURL:[NSURL URLWithString:self.url]];
}

- (void)viewWillAppear:(BOOL)animated{
    [super viewWillAppear:animated];
    if (self.webViewAdapter && [self.webViewAdapter respondsToSelector:@selector(webAppearShouldScrollToTop:)]) {
        if ([self.webViewAdapter webAppearShouldScrollToTop:_webView.scrollView]) {
            _webView.scrollView.contentOffset = CGPointZero;
        }
    }
}

- (void) viewDidLayoutSubviews{
    [super viewDidLayoutSubviews];
    UIEdgeInsets inset = UIEdgeInsetsZero;
    if (self.webViewAdapter) {
        BOOL adjustInsetAutomatically = YES;
        if ([self.webViewAdapter respondsToSelector:@selector(webScrollViewAutomaticallyAdjustInsets)]) {
            adjustInsetAutomatically = [self.webViewAdapter webScrollViewAutomaticallyAdjustInsets];
        }
        if (!adjustInsetAutomatically && [self.webViewAdapter respondsToSelector:@selector(webViewInset:)]) {
            inset = [self.webViewAdapter webViewInset:self];
        }
    }
    __weak typeof(self) weakSelf = self;
    [_webView mas_makeConstraints:^(MASConstraintMaker *make) {
        __strong typeof(self) strongSelf = weakSelf;
        make.edges.equalTo(strongSelf.view).with.insets(inset);
    }];
    if (self.webViewAdapter && [self.webViewAdapter respondsToSelector:@selector(controllerViewLayoutSubviews)]) {
        [self.webViewAdapter controllerViewLayoutSubviews];
    }
}

- (void) webViewInit{
    WKUserContentController *contentController = [[WKUserContentController alloc] init];
    [contentController addScriptMessageHandler:self name:self.interfaceName];
    
    _webViewConfiguration = [[WKWebViewConfiguration alloc] init];
    _webViewConfiguration.userContentController = contentController;
    //    if (@available(iOS 9.0, *)) {
    //        _webViewConfiguration.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];
    //    } else {
    //        // Fallback on earlier versions
    //    }
    _webViewConfiguration.processPool = [WkSharedProcessPool sharedProcessPool];
    
    //    WKUserScript * cookieScript = [[WKUserScript alloc] initWithSource: @"document.cookie ='TeskCookieKey1=TeskCookieValue1';document.cookie = 'TeskCookieKey2=TeskCookieValue2';"injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO];
    //    [contentController addUserScript:cookieScript];
    
    _webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:_webViewConfiguration];
    [_webView addJavascriptInterface:self.interfaceProvider forName:self.interfaceName];
    _webView.navigationDelegate = self;
    _webView.UIDelegate = self;
    _webView.allowsBackForwardNavigationGestures = YES;
    _webView.scrollView.bounces = NO;
    _webView.scrollView.contentInset = UIEdgeInsetsZero;
    _webView.scrollView.scrollIndicatorInsets = UIEdgeInsetsZero;
    _webView.scrollView.layer.masksToBounds = NO;
    _webView.scrollView.delegate = self;
    [self.view addSubview:_webView];
    
    BOOL adjustInsetAutomatically = YES;
    if (self.webViewAdapter && [self.webViewAdapter respondsToSelector:@selector(webScrollViewAutomaticallyAdjustInsets)]) {
        adjustInsetAutomatically = [self.webViewAdapter webScrollViewAutomaticallyAdjustInsets];
    }
    if (adjustInsetAutomatically) {
        if (@available(iOS 11.0, *)) {
            _webView.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAutomatic;
        }else{
            self.automaticallyAdjustsScrollViewInsets = YES;
        }
    }else{
        if (@available(iOS 11.0, *)) {
            _webView.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
        }else{
            self.automaticallyAdjustsScrollViewInsets = NO;
        }
    }
#ifdef FETCH_TITLE_USE_KVO
    [_webView addObserver:self
               forKeyPath:@"title"
                  options:(NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld)
                  context:nil];
#endif
    if (@available(iOS 11.0, *)) {
        WKHTTPCookieStore *cookieStore = self.webView.configuration.websiteDataStore.httpCookieStore;
        [cookieStore addObserver:self];
    } else {
        // Fallback on earlier versions
    }
}

/**
 *  1、暂时不考虑302跳转
 *  2、http/wk 同步cookie，NSHTTPCookieStorage是中转站
 *      wk2native：notificate to httpcookie and share with other wkwebview by 'progcess Pool'
 *      native2wk：set when loadurl and 显性通知
 *  3、rule to handle httponly-cookie
 
 
 pending:
    当 WKHTTPCookieStore 有一个默认特征的会话cookie时（httponly secure_no），相当于服务器注入的
    同步 NSHTTPCookieStorage 到 WKHTTPCookieStore 时，并没有及时setCookie,
    but when set secure yes(https accordingly),it's instant
 
    当 WKHTTPCookieStore 使用NSHTTPCookieStorage注入的cookie时，同步总是即时的
 */
- (void)setCookeis:(NSArray <NSHTTPCookie *>*)cookies url:(NSURL *)url completionHandler:(void(^)(void))completion{
    if (@available(iOS 11.0, *)) {
        if (cookies && cookies.count) {
            __block NSInteger fixedCount = 0;
            WKHTTPCookieStore *cookieStore = self.webView.configuration.websiteDataStore.httpCookieStore;
            for (NSHTTPCookie *cookie in cookies) {
//                NSLog(@"--->%@",cookie);
//                NSHTTPCookie *willSyncCookie = cookie;
                
                NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary: cookie.properties];
                if (url && [url.scheme isEqualToString:@"https"] &&
                    [cookie.name isEqualToString:@"sessionid"] &&
                    [cookie.domain isEqualToString:url.host] &&
                    [cookie.path isEqualToString:@"/"] &&
                    !cookie.sessionOnly) {
                    [dict setObject:@"TRUE" forKey:NSHTTPCookieSecure]; // providing any value,for example 'fasle',means need secure env
                }
                if ([cookie.name isEqualToString:@"sessionid"] && !cookie.isHTTPOnly) {
                    [dict setObject:@"true" forKey:@"HttpOnly"];
                }
                NSHTTPCookie *willSyncCookie = [NSHTTPCookie cookieWithProperties:dict];
                
                [cookieStore setCookie:willSyncCookie completionHandler:^{
                    fixedCount ++;
                    if (fixedCount == cookies.count) {
                        if (completion) {
                            completion();
                        }
                    }
                }];
            }
        }else if(completion){
            completion();
        }
    } else {
        // Fallback on earlier versions
    }
}

//从 http 同步cookie到webCookiestore
- (void)syncCookiesSupportWithURL:(NSURL *)url completion:(void(^)(void))completion{
    
    if (@available(iOS 11.0, *)) {
        NSHTTPCookieStorage *cookieJar = [NSHTTPCookieStorage sharedHTTPCookieStorage];
        [self setCookeis:[cookieJar cookies] url:url completionHandler:^{
            if (completion) {
                completion();
            }
        }];
        
    }else if (completion){
        completion();
    }
}

#pragma mark --
- (void)cookiesDidChangeInCookieStore:(WKHTTPCookieStore *)cookieStore{ //考虑拿出来，以免当前页面消失时，setCookie还未完成
    [cookieStore getAllCookies:^(NSArray<NSHTTPCookie *> * cookies) {
        for (NSHTTPCookie *cookie in cookies) {
            
            NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary: cookie.properties];
            if ([cookie.name isEqualToString:@"sessionid"] && !cookie.isHTTPOnly) {
                [dict setObject:@"true" forKey:@"HttpOnly"];
            }
            NSHTTPCookie *willCookie = [NSHTTPCookie cookieWithProperties:dict];
            
            NSHTTPCookieStorage *cookieStorage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
            cookieStorage.cookieAcceptPolicy = NSHTTPCookieAcceptPolicyAlways;
            [cookieStorage setCookie:willCookie];
        }
    }];
    
    if (self.delegate && [self.delegate respondsToSelector:@selector(cookieStoreDidChange:)]) {
        [self.delegate cookieStoreDidChange:cookieStore];
    }
}

- (void)addProgressBar{
    _progressBar = [[UIProgressView alloc] initWithFrame:(CGRectMake(0, 0, CGRectGetWidth(_webView.bounds), 1.))];
    _progressBar.hidden = YES;
    _progressBar.transform = CGAffineTransformMakeScale(1.0f, 1.5f);
    [self.webView addSubview:_progressBar];
}

- (void)startProgress:(CGFloat)progress{
    if (!self.disableProgress && !_progressBar) {
        [self addProgressBar];
    }
    if (_progressBar) {
        [_progressBar setHidden:NO];
        
        _progressTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(_progressTimer, DISPATCH_TIME_NOW, 0.2 * NSEC_PER_SEC, 0.2 * NSEC_PER_SEC);
        dispatch_source_set_event_handler(_progressTimer, ^{
            [_progressBar setProgress:progress animated:YES];
        });
        // Start the timer
        dispatch_resume(_progressTimer);
    }
}
- (void)endProgress{
    if (_progressTimer) {
        dispatch_source_cancel(_progressTimer);
    }
    if (_progressBar) {
        [UIView animateWithDuration:.25f delay:0.3f options:(UIViewAnimationOptionCurveEaseOut) animations:^{
            _progressBar.transform = CGAffineTransformMakeScale(1.0f, 1.4f);
            _progressBar.progress = 1.;
        } completion:^(BOOL finished) {
            [_progressBar setHidden:YES];
        }];
    }
}

- (void)dealloc{
    if (_progressTimer) {
        dispatch_source_cancel(_progressTimer);
    }
    if (_webView) {
        [_webView removeObserver:self forKeyPath:@"title"];
        if (@available(iOS 11.0, *)) {
            WKHTTPCookieStore *cookieStore = self.webView.configuration.websiteDataStore.httpCookieStore;
            if (cookieStore) {
                [cookieStore removeObserver:self];
            }
        }
    }
}

#pragma mark --
- (BOOL)canGoBack{
    
    return [_webView canGoBack];
}
- (void)goBack{
    if ([_webView canGoBack]) {
        [super goBack];
        [_webView goBack];
        WKBackForwardListItem *item = [_webView.backForwardList backItem];
        [_webView goToBackForwardListItem:item];
    }
}
- (BOOL)canGoForward{
    return [_webView canGoForward];
}
- (void)goForward{
    if ([_webView canGoForward]) {
        [_webView goForward];
    }
}
- (void)reloadURL{
    [super reloadURL];
    __weak typeof(self) weakself = self;
    
    [self syncCookiesSupportWithURL:[NSURL URLWithString:self.url] completion:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakself.webView reload];
        });
    }];
}
- (void)openURL:(NSURL*)url{
    [super openURL:url];
    __weak typeof(self) weakself = self;
    [self syncCookiesSupportWithURL:url completion:^{
        NSMutableURLRequest* targetRequest = [NSMutableURLRequest requestWithURL:url];
        if (weakself.delegate && [weakself.delegate respondsToSelector:@selector(requestHeaderField:)]) {
            NSDictionary *fields = [weakself.delegate requestHeaderField:url];
            for (NSInteger i = 0; i < fields.allKeys.count; i++) {
                NSString *key = fields.allKeys[i];
                [targetRequest setValue:fields[key] forHTTPHeaderField:key];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            //            NSString *cookie = [self readCurrentCookie];
            //            [targetRequest setValue:cookie forHTTPHeaderField:@"Cookie"];
            [weakself.webView loadRequest:targetRequest];
        });
    }];
}
//-(NSString *)readCurrentCookie{
//    NSMutableDictionary *cookieDic = [NSMutableDictionary dictionary];
//    NSMutableString *cookieValue = [NSMutableString stringWithFormat:@""];
//    NSHTTPCookieStorage *cookieJar = [NSHTTPCookieStorage sharedHTTPCookieStorage];
//    for (NSHTTPCookie *cookie in [cookieJar cookies]) {
//        [cookieDic setObject:cookie.value forKey:cookie.name];
//    }
//
//    // cookie重复，先放到字典进行去重，再进行拼接
//    for (NSString *key in cookieDic) {
//        NSString *appendString = [NSString stringWithFormat:@"%@=%@;", key, [cookieDic valueForKey:key]];
//        [cookieValue appendString:appendString];
//    }
//    return cookieValue;
//}

- (void)stopLoading{
    [super stopLoading];
    [_webView stopLoading];
}
- (void)loadHTMLString:(NSString *)string baseURL:(NSURL *)baseURL{
    
    [_webView loadHTMLString:string baseURL:baseURL];
}
- (void)evaluateJavaScript:(NSString*)javaScriptString completeBlock:(void(^)(__nullable id obj))complete{
    [_webView evaluateJavaScript:javaScriptString completionHandler:^(id _Nullable obj, NSError * _Nullable error) {
        if (complete != nil) {
            complete(obj);       
        }
    }];
}

#pragma mark --
- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context{
    if([keyPath isEqualToString:@"title"]){
        NSString *newTitle = [change objectForKey:@"new"];
        if(newTitle != nil){
            if(![newTitle hasPrefix:@"{"] && ![newTitle hasSuffix:@"}"]){
                if (self.delegate && [self.delegate respondsToSelector:@selector(documentTitleChanged:)]) {
                    [self.delegate documentTitleChanged:newTitle];
                }
            }
        }
    }else{
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

#pragma mark -- scrollview delegate
- (void)scrollViewDidScroll:(UIScrollView *)scrollView{
    if (self.webViewAdapter && [self.webViewAdapter respondsToSelector:@selector(webMonitorScroll:)]) {
        [self.webViewAdapter webMonitorScroll:scrollView];
    }
}

# pragma mark - scriptmessage handler
- (void) userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message{
    
}

# pragma mark - navigationDelegate

- (void) webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler{
    NSURL *URL = navigationAction.request.URL;
    BOOL res = NO;
#ifdef FETCH_TITLE_USE_KVO
#else
    res = [self disturb_shouldStartRequest:URL];
#endif
    
    if (!res && self.delegate && [self.delegate respondsToSelector:@selector(URLWillLoad:)]) {
        [self.delegate URLWillLoad:URL];
        decisionHandler(WKNavigationActionPolicyAllow);
    }else{
        decisionHandler(WKNavigationActionPolicyCancel);
    }
}

- (void) webView:(WKWebView *)webView decidePolicyForNavigationResponse:(WKNavigationResponse *)navigationResponse decisionHandler:(void (^)(WKNavigationResponsePolicy))decisionHandler{
    decisionHandler(WKNavigationResponsePolicyAllow);
}

- (void) webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation{
    if (![self isRefreshing]) {
        __weak typeof(WKWebView*) weakWebview = webView;
        [self startProgress:weakWebview.estimatedProgress];
    }
}

- (void) webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error{
    if (self.delegate && [self.delegate respondsToSelector:@selector(URLDidFailLoad:error:)]) {
        [self.delegate URLDidFailLoad:webView.URL error:error];
    }
}
- (void) webView:(WKWebView *)webView didCommitNavigation:(WKNavigation *)navigation{
#ifdef FETCH_TITLE_USE_KVO
#else
    [self disturb_requestDidLoad:webView.URL];
#endif
    if (self.delegate && [self.delegate respondsToSelector:@selector(URLDidLoad:)]) {
        [self.delegate URLDidLoad:webView.URL];
    }
}

- (void) webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation{
    
    [self endRefreshing];
    [self endProgress];
#ifdef FETCH_TITLE_USE_KVO
    if(_webView.title && _webView.title.length > 0){
        NSString *newTitle = _webView.title;
        if (self.delegate && [self.delegate respondsToSelector:@selector(documentTitleChanged:)]) {
            [self.delegate documentTitleChanged:newTitle];
        }
    }
#else
    [self disturb_requestDidFinishoad:webView.URL];
#endif
    if (self.delegate && [self.delegate respondsToSelector:@selector(URLDidFinishLoad:)]) {
        [self.delegate URLDidFinishLoad:webView.URL];
    }
    
//    if (@available(iOS 11.0, *)) {
//        WKHTTPCookieStore *cookieStore = self.webView.configuration.websiteDataStore.httpCookieStore;
//        [cookieStore getAllCookies:^(NSArray<NSHTTPCookie *> * _Nonnull allCookies) {
//            for (NSHTTPCookie *cookie in allCookies) {
//                NSLog(@">>>>%@",cookie);
//            }
//        }];
//    } else {
//        // Fallback on earlier versions
//    }
}
- (void) webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error{
    
    [self endRefreshing];
    [self endProgress];
#ifdef FETCH_TITLE_USE_KVO
#else
    [self disturb_requestDidFailLoad:webView.URL];
#endif
    if (self.delegate && [self.delegate respondsToSelector:@selector(URLDidFailLoad:error:)]) {
        [self.delegate URLDidFailLoad:webView.URL error:error];
    }
}

- (void) webView:(WKWebView *)webView didReceiveServerRedirectForProvisionalNavigation:(WKNavigation *)navigation{
    
}


#pragma ------WKUIDelegate
- (void) webViewDidClose:(WKWebView *)webView{
}

- (void) webViewWebContentProcessDidTerminate:(WKWebView *)webView{
    
}
@end

