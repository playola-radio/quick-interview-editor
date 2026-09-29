# Returned audio inspection fixtures

These small files were generated once for development and committed. The test suite reads them; it does not require ffmpeg or `afconvert` at runtime.

```sh
ffmpeg -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=0.1' -ac 1 -c:a flac -sample_fmt s16 mono-48k.flac
ffmpeg -f lavfi -i 'sine=frequency=440:sample_rate=44100:duration=0.1' -ac 2 -c:a aac -b:a 256k stereo-aac.m4a
ffmpeg -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=0.1' -ac 2 -c:a pcm_s16le -rf64 always stereo-48k-rf64.wav
afconvert -f AIFC -d BEI16 mono-48k.flac mono-48k.aifc
ffmpeg -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=0.1' -ac 1 -c:a pcm_s16be mono-48k.aiff
afconvert -f AIFC -d ima4 mono-48k.aiff mono-48k-lossy.aifc
```

The AAC fixture is renamed to `.wav` at test runtime to prove that inspection uses the container rather than the extension.

`mono-48k-lossy.aifc` holds IMA4-compressed audio inside a genuine AIFC container, proving inspection checks the codec and not just the container type.
