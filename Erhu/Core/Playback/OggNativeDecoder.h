#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Xiph libopusfile/libvorbisfile bridge. Original audio is opened read-only.
@interface ERHUOggDecoder : NSObject
+ (nullable NSDictionary<NSString *, id> *)inspectURL:(NSURL *)url error:(NSError **)error NS_SWIFT_NAME(inspect(_:));
+ (BOOL)decodeURL:(NSURL *)url toURL:(NSURL *)destination isCancelled:(BOOL (^)(void))isCancelled error:(NSError **)error NS_SWIFT_NAME(decode(_:to:isCancelled:));
@end
NS_ASSUME_NONNULL_END
