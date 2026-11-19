// Small decorative components: rating badges, tech pills, cast row.

#import <QuartzCore/QuartzCore.h>
@class PXServer;
@class PXItem;

// Row of rating badges (IMDb, Rotten Tomatoes critics/audience, TMDB) at origin.
CALayer *PXRatingsRow(NSArray *ratings, CGPoint origin);
// Row of outlined pills ("4K", "Dolby Vision", "TrueHD 7.1").
CALayer *PXPillsRow(NSArray *texts, CGPoint origin);

// Detail page header texts (movie, episode, show), drawn off the main thread.
// Title on up to two lines, size fitted to its length; returns its height.
CGFloat PXAddPageTitle(CALayer *parent, NSString *title, CGFloat x, CGFloat y, CGFloat width);
// Summary in whole lines filling the room from y down to bottom.
void PXAddPageSummary(CALayer *parent, NSString *summary, CGFloat x, CGFloat y, CGFloat width, CGFloat bottom);

// Horizontal row of circular cast photos with name and role.
@interface PXCastRow : CALayer
- (instancetype)initWithWidth:(CGFloat)width;
@property (nonatomic, strong) PXServer *server;  // where the photos are resized (set before people)
@property (nonatomic, copy) NSArray *people;      // {name, role, thumb}
@property (nonatomic, readonly) CGFloat height;
@property (nonatomic, assign) BOOL active;
@property (nonatomic, readonly) NSInteger focusIndex;
- (BOOL)moveBy:(NSInteger)delta;
@end
