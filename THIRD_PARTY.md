# Licensing and attributions

The complete MusicFocus client in this repository can be used under GNU AGPL version 3. The original MusicFocus code retains its existing MIT grant. The MIT grant does not relicense HOMR-derived work or third-party assets.

| Component | Source and terms |
| --- | --- |
| Optical music recognition | Christian Liebhardt and HOMR contributors, [HOMR v0.7.1](https://github.com/liebharc/homr/tree/v0.7.1), [upstream license](Development/ScoreRecognitionModels/HOMR-LICENSE.txt). The Swift port adapts the model interface, normalization, staff handling, token vocabulary and group timing. MusicFocus changes through 2026-11-15 include the on-device pipeline, contextual rhythm review, cross-page playback, and show-through handling. |
| ONNX Runtime | Microsoft, version 1.20.0, [MIT](MusicFocus/Resources/ONNXRuntime-LICENSE.txt). |
| SwiftKeychainWrapper | Jason Rendel, version 4.0.1, [MIT](LICENSES/SwiftKeychainWrapper-MIT.txt). |
| Practice pitch | CREPE tiny, converted to Core ML, [source and MIT license](MusicFocus/Resources/PracticePitchModel-LICENSE.txt). |
| Speech detection | Silero VAD and FluidInference conversion, [sources, MIT and Apache-2.0 notices](MusicFocus/Resources/PracticeSpeechClassifier-LICENSE.txt). |
| Vocal classifier | YAMNet and Core ML conversion, [sources and Apache-2.0 notice](MusicFocus/Resources/PracticeVocalClassifier-LICENSE.txt). |
| Fingering recognizer | Adapted UCI pen-digit and UJI pen-character trajectories, [credits, changes and CC BY 4.0](MusicFocus/Resources/FingeringDigits-Credits.txt). |
| Music font | Steinberg Bravura, [SIL Open Font License 1.1](MusicFocus/Resources/Fonts/Bravura-LICENSE.txt). |
| Mechanical click | OleSouWester, Freesound, [source, edits and CC0 dedication](MusicFocus/Resources/MetronomeMechanicalSource.json). |
| Optional piano soundfont | FreePats and Zenph Studios, [attribution and CC BY 3.0](Development/ScoreRecognitionModels/YDP-GrandPiano-LICENSE.txt). Supplied separately for a local recognition build. |

The companion relay’s Node dependencies are listed in its package and lock files under their upstream licenses. Apple frameworks come with the platform SDK. The source release does not grant rights to private scores or training corpora. A distribution containing third-party weights calls for a separate review of the weights, training-data terms, and distribution channel.
