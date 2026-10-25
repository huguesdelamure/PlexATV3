# Contributing

Bug reports, translations and pull requests are welcome.

## Reporting a bug

Please include:
- the Apple TV software version (Settings > General > About);
- what you did, what you expected, what happened;
- for playback problems: the file's video / audio codecs and whether the
  server transcodes (Plex dashboard);
- the end of the log if you run a debug build
  (`/var/mobile/Library/Caches/PlexATV3/plexatv.log`). The log never
  contains your Plex token, but check it for server names or addresses
  before posting.

## Pull requests

- Build with `make` and test on a real Apple TV 3. There is no simulator
  for BackRow. Mention what you tested in the PR.
- Keep the A5 in mind. Measure with `fpsmeter` and `stallwatch` (see the
  README) when you touch scrolling or screen transitions.
- Wrap every user-visible string in `PXL()` / `PXLF()` and add its English
  translation to `App/Resources/en.lproj/Localizable.strings`.
- Never log or display tokens.
- Code style: plain Objective-C with ARC, Core Animation layers (no
  UIViews), short comments only where the code is not obvious.

## Translations

See "Adding a language" in the README. A translation is one
`Localizable.strings` file plus two lines in `Kit/Core/PXLocalize.m`.

## Feature work

Check [docs/PARITY.md](docs/PARITY.md) first, and open an issue before
large changes, so that two people do not write the same feature.
