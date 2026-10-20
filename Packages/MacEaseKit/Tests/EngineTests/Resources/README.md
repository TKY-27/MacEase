# Engine test fixtures

Generated with FFmpeg 9 from its synthetic sources:

```sh
ffmpeg -f lavfi -i testsrc=size=160x96:rate=24 -f lavfi -i sine=frequency=440:sample_rate=48000 -t 2 -c:v h264_videotoolbox -b:v 300k -g 12 -c:a aac -b:a 64k -ac 2 -movflags +faststart ffmpeg-h264-aac.mp4
ffmpeg -display_rotation 90 -i ffmpeg-h264-aac.mp4 -c copy ffmpeg-rotated.mov
```
