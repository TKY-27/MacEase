# Test fixtures

Generated with FFmpeg 9 from its synthetic sources, so no third-party media is
redistributed. Regenerate from this folder:

```sh
ffmpeg -f lavfi -i testsrc=size=96x64:rate=10 -f lavfi -i sine=frequency=440:sample_rate=8000 -t 1 -c:v mjpeg -q:v 8 -c:a pcm_s16le ffmpeg-mjpeg-pcm.avi
ffmpeg -f lavfi -i testsrc=size=96x64:rate=10 -f lavfi -i sine=frequency=440:sample_rate=48000 -t 2 -c:v mpeg4 -g 5 -q:v 8 -c:a ac3 -b:a 64k ffmpeg-mpeg4-ac3.avi
ffmpeg -f lavfi -i testsrc=size=96x64:rate=10 -f lavfi -i sine=frequency=440:sample_rate=44100 -t 2 -c:v h264_videotoolbox -b:v 200k -g 5 -c:a aac -b:a 64k -ac 2 ffmpeg-h264-aac.flv
ffmpeg -f lavfi -i testsrc=size=96x64:rate=30000/1001 -f lavfi -i sine=frequency=440:sample_rate=48000 -i sub.srt -t 2 -map 0 -map 1 -map 2 -c:v mpeg4 -g 10 -q:v 8 -c:a ac3 -b:a 64k -c:s srt ffmpeg-mpeg4-ac3-srt.mkv
```

`sub.srt` holds two cues, "Hello" (0–1 s) and "World" (1–2 s).
