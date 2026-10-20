# Test fixtures

Generated with FFmpeg 9 from its synthetic sources, so no third-party media is
redistributed. Regenerate from this folder:

```sh
ffmpeg -f lavfi -i testsrc=size=96x64:rate=10 -f lavfi -i sine=frequency=440:sample_rate=8000 -t 1 -c:v mjpeg -q:v 8 -c:a pcm_s16le ffmpeg-mjpeg-pcm.avi
ffmpeg -f lavfi -i testsrc=size=96x64:rate=10 -f lavfi -i sine=frequency=440:sample_rate=48000 -t 2 -c:v mpeg4 -g 5 -q:v 8 -c:a ac3 -b:a 64k ffmpeg-mpeg4-ac3.avi
ffmpeg -f lavfi -i testsrc=size=96x64:rate=10 -f lavfi -i sine=frequency=440:sample_rate=44100 -t 2 -c:v h264_videotoolbox -b:v 200k -g 5 -c:a aac -b:a 64k -ac 2 ffmpeg-h264-aac.flv
ffmpeg -f lavfi -i testsrc=size=96x64:rate=30000/1001 -f lavfi -i sine=frequency=440:sample_rate=48000 -i sub.srt -t 2 -map 0 -map 1 -map 2 -c:v mpeg4 -g 10 -q:v 8 -c:a ac3 -b:a 64k -c:s srt ffmpeg-mpeg4-ac3-srt.mkv
ffmpeg -f lavfi -i sine=frequency=440:sample_rate=44100 -t 1 -ac 2 -c:a vorbis -strict -2 -q:a 2 -metadata title=Fixture -metadata artist=FFmpeg -metadata album=Tests ffmpeg-vorbis.ogg
ffmpeg -f lavfi -i sine=frequency=440:sample_rate=48000 -t 1 -ac 2 -c:a libopus -b:a 24k -metadata title=Fixture -metadata artist=FFmpeg -metadata album=Tests ffmpeg-opus.opus
ffmpeg -f lavfi -i color=red:s=8x8 -frames:v 1 cover.png
ffmpeg -f lavfi -i sine=frequency=440:sample_rate=44100 -i cover.png -t 1 -map 0 -map 1 -c:a flac -c:v copy -disposition:v attached_pic -metadata title=Fixture -metadata artist=FFmpeg -metadata album=Tests ffmpeg-flac.flac
ffmpeg -f lavfi -i sine=frequency=440:sample_rate=16000 -f lavfi -i sine=frequency=440:sample_rate=44100 -t 0.5 -map 0 -map 1 -c:a:0 flac -c:a:1 libmp3lame -b:a:1 64k ffmpeg-flac-mp3.mka
```

`sub.srt` holds two cues, "Hello" (0–1 s) and "World" (1–2 s).
