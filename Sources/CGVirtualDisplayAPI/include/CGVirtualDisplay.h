// Private CGVirtualDisplay API declarations
// Sourced from macOS class-dump headers (w0lfschild/macOS_headers) and
// verified against working implementations (BetterDummy, HiDPIScaler,
// node-mac-virtual-display, Chromium).
// Stable across macOS 12+ (Monterey through Sequoia).

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - CGVirtualDisplayMode

@interface CGVirtualDisplayMode : NSObject

@property (readonly, nonatomic) unsigned int width;
@property (readonly, nonatomic) unsigned int height;
@property (readonly, nonatomic) double refreshRate;

- (instancetype)initWithWidth:(unsigned int)width
                       height:(unsigned int)height
                  refreshRate:(double)refreshRate;

@end

#pragma mark - CGVirtualDisplayDescriptor

@interface CGVirtualDisplayDescriptor : NSObject

@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int vendorID;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int serialNum;
@property (retain, nonatomic, nullable) NSString *name;
@property (nonatomic) CGPoint redPrimary;
@property (nonatomic) CGPoint greenPrimary;
@property (nonatomic) CGPoint bluePrimary;
@property (nonatomic) CGPoint whitePoint;
@property (retain, nonatomic, nullable) dispatch_queue_t queue;
@property (copy, nonatomic, nullable) void (^terminationHandler)(void);

@end

#pragma mark - CGVirtualDisplaySettings

@interface CGVirtualDisplaySettings : NSObject

@property (retain, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
@property (nonatomic) unsigned int hiDPI;

@end

#pragma mark - CGVirtualDisplay

@interface CGVirtualDisplay : NSObject

@property (readonly, nonatomic) CGDirectDisplayID displayID;
@property (readonly, nonatomic) unsigned int hiDPI;
@property (readonly, nonatomic, nullable) NSArray<CGVirtualDisplayMode *> *modes;
@property (readonly, nonatomic) unsigned int vendorID;
@property (readonly, nonatomic) unsigned int productID;
@property (readonly, nonatomic) unsigned int serialNum;
@property (readonly, nonatomic, nullable) NSString *name;
@property (readonly, nonatomic) CGSize sizeInMillimeters;
@property (readonly, nonatomic) unsigned int maxPixelsWide;
@property (readonly, nonatomic) unsigned int maxPixelsHigh;

- (nullable instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;

@end

NS_ASSUME_NONNULL_END
