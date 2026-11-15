# Build offline recognition locally

The default Debug and Release configurations build the same MusicFocus project without the OMR assets. An enabled build reads the original PDF page on the device. It needs three upstream ONNX files, a six-part token vocabulary, and a piano soundfont.

## Prepare the files

Use HOMR [v0.7.1](https://github.com/liebharc/homr/tree/0dd86956b15982c4e388029054920ce655a13886). The table identifies the upstream FP32 ONNX files used for this port. The hashes apply to the extracted files. The conversion for MusicFocus consisted of copying and renaming those files; the weights were neither retrained nor quantized.

| Local filename | Upstream archive | Extracted SHA-256 |
| --- | --- | --- |
| `segnet.onnx` | [segnet_308-3296ccd40960f90ca6ab9c035cca945675d30a0f](https://github.com/liebharc/homr/releases/download/onnx_checkpoints/segnet_308-3296ccd40960f90ca6ab9c035cca945675d30a0f.zip) | `6ed36640db4ef5d223098b6d5efe4eda97c66b24a2c72faab8a018c749003a8d` |
| `decoder.onnx` | [decoder_pytorch_model_509-2293bba14bfea47d9d28411339362af15fce4c31](https://github.com/liebharc/homr/releases/download/onnx_checkpoints/decoder_pytorch_model_509-2293bba14bfea47d9d28411339362af15fce4c31.zip) | `99a6ac39770616bc1a20d6c409bb85fbbe21ba47f972984f9ef834fb5741b96f` |
| `encoder.onnx` | [encoder_pytorch_model_509-2293bba14bfea47d9d28411339362af15fce4c31](https://github.com/liebharc/homr/releases/download/onnx_checkpoints/encoder_pytorch_model_509-2293bba14bfea47d9d28411339362af15fce4c31.zip) | `ee5767286c60dc3d567fe72b6560e7285261ede1535b4215153c199ab3057559` |

For a local build, place the extracted ONNX files under `Development/ScoreRecognitionModels/` with the names above. Obtain the [FreePats YDP Grand Piano SF2, version 2016-08-04](https://freepats.zenvoid.org/Piano/acoustic-grand-piano.html) and place `YDP-GrandPiano.sf2` in the same directory. Its expected SHA-256 is `8757076aecf80abdad1e8f8f6168370399b06f94481796986e6e75ceca09ad21`. The vocabulary and both notices are included. The vocabulary follows [upstream token ID order](https://github.com/liebharc/homr/blob/v0.7.1/homr/transformer/vocabulary.py) in this order: rhythm, pitch, lift, position, articulation, slur.

## Enable the feature

Create an untracked `MusicFocus.local.xcconfig` adjacent to `MusicFocus.xcconfig` containing:

```xcconfig
MUSICFOCUS_DEFAULT_Debug = YES
```

Run the normal **MusicFocus** scheme. Open a score and tap **Audition (Preview)** in the reader toolbar or the compact page menu. The packaging script reports the name of any missing resource. For an explicit build-time override, pass `MUSICFOCUS_INCLUDE_HOMR=YES` to xcodebuild. Review the rights for any distribution containing the checkpoints. The training sources associated with 509 and the availability of the weights are documented in the [upstream training log](https://github.com/liebharc/homr/blob/v0.7.1/Training.md#run-509); the published source supplies no separate clearance for downstream distribution of those weights.

## Verify the changes

Run **MusicFocusTests/ScoreSystemGroupingTests** for generated two-sided-print and mixed-staff cases. In a recognition-enabled test, `TEST_RUNNER_SCORE_GROUP_NOISE_PDF` supplies a local copy of the two-page regression scan and `TEST_RUNNER_SCORE_GROUP_CONTROL_PDF` supplies a clean one-system control. Those optional checks use the specific layouts described in the tests. **ScoreMeasureReviewTests** covers contextual re-reading in Debug. Recognition reads the original PDF layer, while annotation state and playback caches remain separate.
