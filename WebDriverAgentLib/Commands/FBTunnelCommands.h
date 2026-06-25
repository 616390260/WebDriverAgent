/**
 * 4G reverse tunnel command handler for WebDriverAgent.
 * Adds POST /tunnel/config so MacAutoClick can configure the in-process
 * device reverse tunnel after WDA starts.
 */

#import <Foundation/Foundation.h>

#import "FBCommandHandler.h"

NS_ASSUME_NONNULL_BEGIN

@interface FBTunnelCommands : NSObject <FBCommandHandler>

@end

NS_ASSUME_NONNULL_END
