#import "FBDeviceReverseTunnelClient.h"

@interface FBDeviceReverseTunnelClient ()
@property (nonatomic, copy) NSString *wsUrl;
@property (nonatomic, copy) NSString *token;
@property (nonatomic, copy) NSString *tenant;
@property (nonatomic, copy) NSString *udid;
@property (nonatomic, copy) NSString *deviceName;
@property (nonatomic, copy) NSString *appVersion;
@property (nonatomic, assign) NSInteger port;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSURLSessionWebSocketTask *ws;
@property (nonatomic, assign) NSInteger epoch;   // bumped on (re)connect/stop; stale callbacks bail
@property (nonatomic, assign) NSInteger fails;   // reconnect backoff counter
@property (nonatomic, strong) dispatch_queue_t q;
@end

@implementation FBDeviceReverseTunnelClient

+ (instancetype)shared
{
  static FBDeviceReverseTunnelClient *instance;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{ instance = [[FBDeviceReverseTunnelClient alloc] init]; });
  return instance;
}

- (instancetype)init
{
  self = [super init];
  if (self) {
    _q = dispatch_queue_create("com.macautoclick.wda.tunnel", DISPATCH_QUEUE_SERIAL);
    _session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]];
    _epoch = 0;
    _fails = 0;
  }
  return self;
}

- (void)configureWithWsUrl:(NSString *)wsUrl
                     token:(NSString *)token
                    tenant:(NSString *)tenant
                      udid:(NSString *)udid
                      port:(NSInteger)port
                deviceName:(NSString *)deviceName
                appVersion:(NSString *)appVersion
{
  dispatch_async(self.q, ^{
    self.wsUrl = wsUrl ?: @"";
    self.token = token ?: @"";
    self.tenant = (tenant.length > 0) ? tenant : @"2";
    self.udid = udid ?: @"";
    self.port = (port > 0) ? port : 8100;
    self.deviceName = deviceName ?: @"";
    self.appVersion = appVersion ?: @"";
    self.epoch += 1;      // invalidate any previous connection's callbacks
    self.fails = 0;
    [self connect];
  });
}

- (void)stop
{
  dispatch_async(self.q, ^{
    self.epoch += 1;
    [self.ws cancelWithCloseCode:NSURLSessionWebSocketCloseCodeGoingAway reason:nil];
    self.ws = nil;
  });
}

#pragma mark - Connection (all methods below run on self.q)

- (void)connect
{
  if (self.wsUrl.length == 0) { return; }
  NSURL *url = [NSURL URLWithString:self.wsUrl];
  if (url == nil) { [self scheduleReconnect:self.epoch]; return; }

  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
  if (self.token.length > 0) { [request setValue:self.token forHTTPHeaderField:@"APP-TOKEN"]; }
  [request setValue:self.tenant forHTTPHeaderField:@"X-Tenant-Id"];
  [request setValue:@"1" forHTTPHeaderField:@"app-type"];

  [self.ws cancelWithCloseCode:NSURLSessionWebSocketCloseCodeGoingAway reason:nil];
  self.ws = [self.session webSocketTaskWithRequest:request];
  [self.ws resume];

  NSInteger ep = self.epoch;

  // First packet: register (marks this udid online on the backend).
  [self sendJSON:@{
    @"type": @"register",
    @"udid": self.udid,
    @"tenantId": self.tenant,
    @"wdaPort": @(self.port),
    @"deviceName": self.deviceName,
    @"appVersion": self.appVersion,
  }];
  [self receiveForEpoch:ep];
  [self pingForEpoch:ep];
}

- (void)sendJSON:(NSDictionary *)object
{
  NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
  if (data == nil) { return; }
  NSURLSessionWebSocketMessage *message = [[NSURLSessionWebSocketMessage alloc] initWithData:data];
  [self.ws sendMessage:message completionHandler:^(NSError * _Nullable error) {
    // Ignore send errors; a broken connection surfaces via receive's error and drives reconnect.
  }];
}

- (void)receiveForEpoch:(NSInteger)ep
{
  __weak typeof(self) weakSelf = self;
  [self.ws receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage * _Nullable message, NSError * _Nullable error) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (strongSelf == nil) { return; }
    dispatch_async(strongSelf.q, ^{
      if (ep != strongSelf.epoch) { return; }            // stale connection
      if (error != nil) { [strongSelf scheduleReconnect:ep]; return; }
      strongSelf.fails = 0;
      [strongSelf handleMessage:message epoch:ep];
      [strongSelf receiveForEpoch:ep];                   // keep receiving
    });
  }];
}

- (void)handleMessage:(NSURLSessionWebSocketMessage *)message epoch:(NSInteger)ep
{
  NSData *data = nil;
  if (message.type == NSURLSessionWebSocketMessageTypeData) {
    data = message.data;
  } else if (message.string != nil) {
    data = [message.string dataUsingEncoding:NSUTF8StringEncoding];
  }
  if (data == nil) { return; }
  NSDictionary *object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  if (![object isKindOfClass:[NSDictionary class]]) { return; }
  NSString *type = object[@"type"];
  if ([type isEqualToString:@"wdaRequest"]) {
    [self forwardToWDA:object epoch:ep];
  } else if ([type isEqualToString:@"ping"]) {
    [self sendJSON:@{ @"type": @"pong", @"udid": self.udid }];
  }
}

/// Forward one backend `wdaRequest` to the local WDA (127.0.0.1), reply `wdaResponse`.
- (void)forwardToWDA:(NSDictionary *)r epoch:(NSInteger)ep
{
  NSString *requestId = r[@"requestId"];
  if (![requestId isKindOfClass:[NSString class]]) { return; }
  NSString *method = [r[@"method"] isKindOfClass:[NSString class]] ? r[@"method"] : @"GET";
  NSString *path = [r[@"path"] isKindOfClass:[NSString class]] ? r[@"path"] : @"/status";
  if (![path hasPrefix:@"/"]) { path = [@"/" stringByAppendingString:path]; }
  NSString *urlString = [NSString stringWithFormat:@"http://127.0.0.1:%ld%@", (long)self.port, path];
  NSString *queryString = r[@"queryString"];
  if ([queryString isKindOfClass:[NSString class]] && queryString.length > 0) {
    urlString = [urlString stringByAppendingFormat:@"?%@", queryString];
  }

  NSURL *url = [NSURL URLWithString:urlString];
  if (url == nil) {
    [self sendJSON:@{
      @"type": @"wdaResponse", @"requestId": requestId, @"udid": self.udid,
      @"statusCode": @502, @"headers": @{}, @"bodyBase64": @"",
      @"errorMessage": [@"bad local url: " stringByAppendingString:urlString],
    }];
    return;
  }

  NSMutableURLRequest *localRequest = [NSMutableURLRequest requestWithURL:url];
  localRequest.HTTPMethod = method;
  localRequest.timeoutInterval = 15;
  NSDictionary *headers = r[@"headers"];
  if ([headers isKindOfClass:[NSDictionary class]]) {
    for (NSString *key in headers) {
      if (![key isKindOfClass:[NSString class]] || [self isHopByHopHeader:key]) { continue; }
      id value = headers[key];
      if ([value isKindOfClass:[NSString class]]) { [localRequest setValue:value forHTTPHeaderField:key]; }
    }
  }
  NSString *bodyBase64 = r[@"bodyBase64"];
  if ([bodyBase64 isKindOfClass:[NSString class]] && bodyBase64.length > 0) {
    NSData *body = [[NSData alloc] initWithBase64EncodedString:bodyBase64 options:0];
    if (body != nil) { localRequest.HTTPBody = body; }
  }

  __weak typeof(self) weakSelf = self;
  NSURLSessionDataTask *task = [self.session dataTaskWithRequest:localRequest
                                              completionHandler:^(NSData * _Nullable respData, NSURLResponse * _Nullable response, NSError * _Nullable error) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (strongSelf == nil) { return; }
    dispatch_async(strongSelf.q, ^{
      if (ep != strongSelf.epoch) { return; }
      NSInteger statusCode = 502;
      NSDictionary *outHeaders = @{};
      NSString *outBody = @"";
      NSString *errorMessage = nil;
      if (error != nil) {
        errorMessage = error.localizedDescription;
      } else if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        statusCode = http.statusCode;
        NSString *contentType = http.allHeaderFields[@"Content-Type"] ?: @"application/json";
        outHeaders = @{ @"content-type": contentType };
        outBody = [respData base64EncodedStringWithOptions:0] ?: @"";
      }
      NSMutableDictionary *payload = [@{
        @"type": @"wdaResponse", @"requestId": requestId, @"udid": strongSelf.udid,
        @"statusCode": @(statusCode), @"headers": outHeaders, @"bodyBase64": outBody,
      } mutableCopy];
      if (errorMessage != nil) { payload[@"errorMessage"] = errorMessage; }
      [strongSelf sendJSON:payload];
    });
  }];
  [task resume];
}

- (void)pingForEpoch:(NSInteger)ep
{
  __weak typeof(self) weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12 * NSEC_PER_SEC)), self.q, ^{
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (strongSelf == nil) { return; }
    if (ep != strongSelf.epoch) { return; }
    [strongSelf.ws sendPingWithPongReceiveHandler:^(NSError * _Nullable error) { }];
    [strongSelf pingForEpoch:ep];
  });
}

- (void)scheduleReconnect:(NSInteger)ep
{
  if (ep != self.epoch) { return; }
  self.epoch += 1;                          // invalidate the dead connection
  NSInteger newEpoch = self.epoch;
  self.fails = MIN(self.fails + 1, 4);
  int64_t delaySeconds = (int64_t)(1 << self.fails);   // 2, 4, 8, 16, 16 s
  __weak typeof(self) weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delaySeconds * (int64_t)NSEC_PER_SEC), self.q, ^{
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (strongSelf == nil) { return; }
    if (newEpoch != strongSelf.epoch) { return; }
    [strongSelf connect];
  });
}

- (BOOL)isHopByHopHeader:(NSString *)key
{
  static NSSet *hopByHop;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    hopByHop = [NSSet setWithArray:@[ @"host", @"connection", @"content-length",
                                      @"transfer-encoding", @"authorization", @"app-token", @"x-tenant-id" ]];
  });
  return [hopByHop containsObject:key.lowercaseString];
}

@end
