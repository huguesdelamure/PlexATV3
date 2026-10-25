// Screen factories, so screens do not import each other.

#import "PXScreen.h"
@class PXItem, PXServer;

PXScreen *PXHomeScreenNew(void);
PXScreen *PXHomeScreenOnSettings(void);    // after a language change
// Plex Home profile picker; atLaunch: Menu leaves the app (no PIN bypass).
PXScreen *PXProfilesScreenNew(BOOL atLaunch, void (^completion)(void));
PXScreen *PXHomeScreenForServer(PXServer *server);          // home + libraries of one server
// Servers shown on the home (first launch, Réglages); completion after "Valider".
PXScreen *PXServersScreenNew(void (^completion)(void));
// "Serveurs" tab: every server of the account, opens its home.
PXScreen *PXServerListScreenNew(BOOL embedded);
PXScreen *PXLinkScreenNew(void (^completion)(void));
// embedded: shown inside the home tabs (no title, focus handed back on Up/Menu).
PXScreen *PXLibraryScreenNew(NSDictionary *section, BOOL embedded);   // /library/sections entry
// Poster grid of any item list of a server (collection, playlist, filmography).
PXScreen *PXItemListScreenNew(NSString *title, NSString *path, PXServer *server);
PXScreen *PXItemListScreenNewEmbedded(NSString *title, NSString *path, PXServer *server);   // home tab
// Personal media library (no metadata agent): 16:9 artwork, no posters.
BOOL PXSectionIsLandscape(NSDictionary *section);
PXScreen *PXSettingsScreenNew(BOOL embedded);
PXScreen *PXSearchScreenNew(BOOL embedded);
PXScreen *PXScreenForItem(PXItem *item);                   // detail / show / season
// Same, when only the ratingKey is known (launcher): loads, then swaps itself.
PXScreen *PXScreenForRatingKey(NSString *ratingKey);
PXScreen *PXScreenForRatingKeyOnServer(NSString *ratingKey, PXServer *server);   // nil = primary
// Starts playback of a movie/episode at offset seconds (-1 = resume point from the server).
PXScreen *PXPlayerScreenNew(PXItem *item, double offset);

// Music: album page and the "now playing" screen of PXMusicPlayer.
PXScreen *PXAlbumScreenNew(PXItem *album);
PXScreen *PXNowPlayingScreenNew(void);
