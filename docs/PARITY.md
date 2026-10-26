# Feature parity with the official Plex clients

Goal: everything the official Plex apps for TVs do, within what the Apple TV 3
hardware allows (A5 SoC, 512 MB RAM, 8 GB flash, iOS 8.4, H.264-only decoder,
HDMI 1.4 1080p).

Status: **done**, **planned** (feasible, not written yet), **limited** (works
with a hardware/OS compromise), **no** (not possible on this device).

## Hardware and OS constraints

| Constraint | Consequence |
|---|---|
| Video decoder: H.264 only, up to 1080p30 | HEVC, AV1, VC-1, MPEG-2, 4K and 1080p60 are converted by the server (Plex transcoder) to H.264 1080p. |
| No HDR output | HDR10 / Dolby Vision sources need server tone mapping (PMS setting). |
| Audio decode: AAC; AC-3 stalls AVPlayer on this device (measured) | Everything else (AC-3, E-AC-3, DTS, TrueHD, FLAC 5.1) is converted to AAC by the server. No passthrough, no Atmos. |
| Bitmap subtitles (PGS, VobSub) and styled ASS | Burned into the video by the server; text subtitles (SRT, WebVTT) delivered as text. |
| iOS 8 TLS stack (TLS 1.2, no ChaCha20, no AES-GCM) | plex.tv only accepts AES-GCM and fails; clients.plex.tv, *.plex.direct and the online providers (discover, vod, metadata .provider.plex.tv) accept ECDHE-CBC and work (measured on the device). |
| 512 MB RAM, A5 CPU | Images decoded off the main thread at display size, cell recycling, cached text rendering. |
| 8 GB flash, mostly system | Offline downloads only for small files, if at all. |
| HDMI system volume fixed | Volume = per-player gain (AVPlayer.volume), measured working. |

## Matrix

### Account and servers

| Feature | Status |
|---|---|
| plex.tv sign-in with a PIN (plex.tv/link) | done |
| Server discovery (resources), remote access (plex.direct HTTPS, relay), automatic reconnection | done |
| Several servers at once: libraries of every server, merged home | done (servers chosen at first launch, changeable in Settings) |
| Server picker / preferred server | done |
| Plex Home users: switch user, PIN, managed users and parental restrictions | done (picker at launch or last profile, set in Settings; restrictions applied by the server) |
| Sign out | done |

### Browsing

| Feature | Status |
|---|---|
| Home hubs (continue watching, on deck, recently added per library) | done |
| Movie and TV libraries: grid, sort and filters | done (5 filters) |
| Advanced filters (genre, year, resolution, unwatched, collections, labels) | done (genre, decade, unwatched, collections) |
| Other videos / personal media libraries | done (16:9 cards) |
| Movie page: ratings, cast, crew, similar titles, tech badges | done |
| Show / season / episode pages | done |
| Collections | done |
| Playlists (video and audio) | done (video playlists tab; audio playlists open as track lists) |
| Extras: trailers, behind the scenes, deleted scenes | done |
| Actor / director pages (filmography in the library) | done (actors) |
| Mark watched / unwatched, rating | done |
| Music libraries: artists, albums, tracks | done |
| Photo libraries and slideshows | done |
| Top Shelf on the Apple TV home | done |

### Search

| Feature | Status |
|---|---|
| Search by type, suggestions before typing | done |
| Unified search across servers | done |
| Search in online content (Discover) | done ("More on Plex" row) |
| Voice search | no (no microphone on the remote) |

### Playback

| Feature | Status |
|---|---|
| Direct play H.264/AAC, server conversion for everything else | done |
| Resume, progress and watched sync, timeline reports | done |
| Version choice (4K / 1080p / other editions) | done |
| Play from another server ("other locations") | done (matched by Plex GUID) |
| Audio and subtitle track choice, preferred languages | done |
| Subtitle search and download (OpenSubtitles through PMS) | done |
| Subtitle size / position / style | done (size, for subtitles burned by the server) |
| Quality setting (bitrate) | done |
| Skip intro / credits, chapters, scrub thumbnails | done |
| Next episode / autoplay, play queue | done (next episode), play queue planned |
| Shuffle / play all for a show or season | done (shuffle a show) |
| Audio boost, night mode | limited (server-side audio normalization only) |
| Background music / theme songs | done |
| Watch Together | limited (plex.tv service, TLS) |

### Music

| Feature | Status |
|---|---|
| Artist / album / track browsing, album art | done |
| Audio player with now playing screen, queue, shuffle, repeat | done |
| Gapless, lossless | limited (server converts FLAC/ALAC to AAC when needed) |
| Lyrics (Plex Pass) | planned |
| Radios / mixes (Sonic features, server-side) | planned |

### Live TV and DVR (PMS tuner)

| Feature | Status |
|---|---|
| Live channels (HLS from the PMS) | planned (needs a server with a tuner to test) |
| Guide (EPG) | limited (EPG from plex.tv, TLS) |
| Recording schedule | planned |

### Online content

| Feature | Status |
|---|---|
| Watchlist | done |
| Free movies and shows (Plex VOD) | no on iOS 8: fMP4 HLS segments (iOS 10+) on a CDN that refuses the iOS 8 cipher suites; would need a remux relay |
| Discover hubs (trending, coming soon) | done ("Discover" tab) |

### Remote control and casting

| Feature | Status |
|---|---|
| Control from the Plex mobile app (Companion / "Cast to") | done (GDM + player API on port 32500; tested with a simulated controller) |

### Languages and keyboards

| Feature | Status |
|---|---|
| UI in several languages (strings files, at least French and English), following the Apple TV language, overridable in Settings | done (French, English) |
| On-screen keyboard layouts per language (AZERTY, QWERTY, QWERTZ, accented letters), switchable | done (AZERTY, QWERTY, QWERTZ) |
| Dates, times, durations in the user's locale | done |
| Server metadata (summaries, genres) in the UI language (X-Plex-Language) | done (header sent); local genre translation as a fallback |

### Offline

| Feature | Status |
|---|---|
| Downloads | no (storage) |

## Order of work

1. ~~Multi-server: connections to every server, merged home and libraries,
   unified search, version choice, other locations.~~ done
2. ~~Languages and keyboards.~~ done
3. ~~Plex Home users.~~ done
4. ~~Collections, playlists, extras, actor pages~~ done; advanced filters.
5. ~~Music.~~ done
6. ~~Photos.~~ done
7. ~~Companion (control from a phone).~~ done
8. Live TV / DVR.
9. Online content (watchlist, Discover, free movies): the provider hosts work on the device.
