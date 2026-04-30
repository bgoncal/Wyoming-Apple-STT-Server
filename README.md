# Wyoming Apple Speech Server

Native macOS app that exposes Apple's local speech-to-text and text-to-speech engines through the Wyoming protocol so it can plug into Home Assistant voice pipelines.

## What it does

- Hosts a TCP Wyoming server on macOS
- Advertises `_wyoming._tcp.local.` over Bonjour
- Accepts `describe`, `transcribe`, `audio-start`, `audio-chunk`, and `audio-stop`
- Returns final `transcript` events using Apple's on-device Speech framework
- Accepts `synthesize` requests and returns `audio-start`, `audio-chunk`, and `audio-stop`
- Advertises installed Apple system voices as Wyoming TTS speakers
- Provides a small desktop control panel for status, settings, logs, and recent transcripts

## Assumptions

- Built against the macOS 26 SDK because it uses `SpeechTranscriber`
- Designed for Apple Silicon Macs running a compatible macOS version

## Running

1. Open `WyomingAppleSpeechServer.xcodeproj` in Xcode 26+
2. Click on "▶️" (Run)

## Home Assistant

1. Open the app and allow speech recognition access the first time it starts.
2. Confirm the server is listening on the expected port, default `10300`.
3. In Home Assistant, add the Wyoming Protocol integration.
4. Use Bonjour discovery if it appears, or manually enter this Mac's LAN IP and the selected port.

## Notes

The Wyoming service metadata advertises one ASR model named `apple-local-stt` and the installed Apple voices as Wyoming TTS voices. TTS audio is returned as raw 16-bit PCM using the sample rate produced by Apple's speech synthesizer.
