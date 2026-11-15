# MusicFocus

MusicFocus is an iPhone and iPad app for reading PDF scores, annotating them with Apple Pencil, and tracking practice time. The score reader includes a metronome, voice reminders, fingering annotations and page-level practice records.

## Build the app

1. Open `MusicFocus.xcodeproj` in Xcode. Select the **MusicFocus** scheme.
2. Let Swift Package Manager resolve the versions in `Package.resolved`. Select an iPhone or iPad simulator and press Run. For a physical device, select your own signing team and a bundle identifier available to your account.
3. In the Test navigator, run **MusicFocusTests**. The grouping, rhythm, annotation and practice-history tests include generated inputs. Tests requiring optional personal fixtures skip when their inputs are absent.

The public checkout builds with the optical music recognition models disabled. The application target supports iOS/iPadOS 18 and later. Development was verified with Xcode 27 and an iPadOS 26.5 simulator.

```sh
xcodebuild -project MusicFocus.xcodeproj -scheme MusicFocus \
  -configuration Debug -destination 'generic/platform=iOS Simulator' build
```

## Offline score recognition

The source includes the Swift implementation for rendering the original PDF layer, grouping staves, decoding with HOMR, reviewing suspicious measures and producing a playable timeline. The scanner can compare a second rendering when faint print from the reverse side looks like an extra staff. The change applies to recognition pixels and preserves the PDF and its annotations. A faint clef or a small cue staff is evidence to keep a front-side staff. Recognition can still miss complex rhythms and overlapping voices.

[Local recognition build, model provenance and verification](Development/README.md)

## License

The combined client source, including its HOMR adaptations, is available under the [GNU Affero General Public License v3](LICENSE). MusicFocus original code also retains its [MIT license](LICENSES/MusicFocus-MIT.txt). Third-party software, source datasets and bundled assets have their own terms. [Attributions and scope](THIRD_PARTY.md)
