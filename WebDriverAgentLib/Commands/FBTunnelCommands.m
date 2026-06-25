/**
 * 4G reverse tunnel command handler for WebDriverAgent.
 *
 * Route: POST /tunnel/config  (no session required)
 * Body : { wsUrl, token, tenantId, udid, port, deviceName, appVersion }
 * Effect: hands the config to FBDeviceReverseTunnelClient, which keeps a
 *         WebSocket to the backend so the phone stays controllable over 4G.
 *
 * Registration is automatic: WDA's FBWebServer collects every class conforming
 * to <FBCommandHandler> via FBClassesThatConformsToProtocol — no manual wiring.
 */

#import "FBTunnelCommands.h"

#import "FBDeviceReverseTunnelClient.h"
#import "FBResponsePayload.h"
#import "FBRoute.h"
#import "FBRouteRequest.h"

@implementation FBTunnelCommands

+ (NSArray *)routes
{
  return @[
    [[FBRoute POST:@"/tunnel/config"].withoutSession respondWithTarget:self action:@selector(handleTunnelConfig:)],
  ];
}

+ (id<FBResponsePayload>)handleTunnelConfig:(FBRouteRequest *)request
{
  NSDictionary *arguments = request.arguments ?: @{};
  NSString *wsUrl = [arguments[@"wsUrl"] isKindOfClass:[NSString class]] ? arguments[@"wsUrl"] : @"";
  NSString *token = [arguments[@"token"] isKindOfClass:[NSString class]] ? arguments[@"token"] : @"";
  NSString *tenant = [arguments[@"tenantId"] isKindOfClass:[NSString class]] ? arguments[@"tenantId"] : @"2";
  NSString *udid = [arguments[@"udid"] isKindOfClass:[NSString class]] ? arguments[@"udid"] : @"";
  NSInteger port = [arguments[@"port"] respondsToSelector:@selector(integerValue)] ? [arguments[@"port"] integerValue] : 0;
  if (port <= 0) { port = 8100; }
  NSString *deviceName = [arguments[@"deviceName"] isKindOfClass:[NSString class]] ? arguments[@"deviceName"] : @"";
  NSString *appVersion = [arguments[@"appVersion"] isKindOfClass:[NSString class]] ? arguments[@"appVersion"] : @"";

  [[FBDeviceReverseTunnelClient shared] configureWithWsUrl:wsUrl
                                                     token:token
                                                    tenant:tenant
                                                      udid:udid
                                                      port:port
                                                deviceName:deviceName
                                                appVersion:appVersion];
  return FBResponseWithOK();
}

@end
