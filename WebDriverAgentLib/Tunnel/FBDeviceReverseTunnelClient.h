/**
 * iOS-side reverse tunnel client — runs inside the WDA process.
 *
 * Configured by MacAutoClick via POST /tunnel/config, then keeps a WebSocket to
 * the backend (wss://.../app/device-tunnel/ws). Sends a `register` first packet,
 * then forwards each `wdaRequest` to the local WDA HTTP server (127.0.0.1:port)
 * and returns the result as `wdaResponse`. Lets the phone stay controllable over
 * 4G after USB is unplugged. Auth headers: APP-TOKEN / X-Tenant-Id / app-type.
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface FBDeviceReverseTunnelClient : NSObject

+ (instancetype)shared;

/// Save config and (re)connect the WebSocket. Calling again restarts the connection.
- (void)configureWithWsUrl:(NSString *)wsUrl
                     token:(NSString *)token
                    tenant:(NSString *)tenant
                      udid:(NSString *)udid
                      port:(NSInteger)port
                deviceName:(NSString *)deviceName
                appVersion:(NSString *)appVersion;

- (void)stop;

@end

NS_ASSUME_NONNULL_END
