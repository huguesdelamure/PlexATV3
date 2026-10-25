# Changelog

Versions follow [Semantic Versioning](https://semver.org): major for
changes that break settings or installation, minor for features, patch for
fixes. Each release is a tag `vX.Y.Z` with a build attached on the GitHub
Releases page (see `scripts/release.sh`).

## [Unreleased]

- Plex Home profiles: "Who's watching?" picker with PIN pad, at launch
  (Settings > Profile at Launch) or from Settings > User; each profile keeps
  its own servers and home selection.

## [1.0.0]

First public release.

- plex.tv sign-in with a PIN; every server of the account (owned and
  shared), local, remote and relay connections; servers chosen for the home.
- Home with merged hubs and live hero, tvOS-style tabs, library grids with
  sort and filters, 16:9 cards for unmatched videos.
- Movie, show, season and episode pages with ratings, cast, technical
  badges and similar titles.
- Unified search across servers, suggestions before typing.
- Hardware H.264 playback, server transcoding for everything else; version
  choice and play from another server; resume and watched sync; audio and
  subtitle choice with preferred languages; chapters, skip intro / credits,
  next episode, scrub thumbnails; volume on the remote.
- Top Shelf on the Apple TV home screen.
- English and French interface, AZERTY / QWERTY / QWERTZ keyboards.
