# Engine test fixtures

Generated with FFmpeg 9 from its synthetic sources:

```sh
ffmpeg -f lavfi -i testsrc=size=160x96:rate=24 -f lavfi -i sine=frequency=440:sample_rate=48000 -t 2 -c:v h264_videotoolbox -b:v 300k -g 12 -c:a aac -b:a 64k -ac 2 -movflags +faststart ffmpeg-h264-aac.mp4
ffmpeg -display_rotation 90 -i ffmpeg-h264-aac.mp4 -c copy ffmpeg-rotated.mov
```

The HDR video fixtures are 64×48, 24-frame x265 Main 10 clips with B-frames,
so FFmpeg writes an edit list. Eight gray bars of 8 pixels use 10-bit luma
codes 96 + 80 × bar, plus 12 on odd frames. The PQ clip carries mastering
display and content light level SEI. Generated with FFmpeg 9.0.2:

```sh
SRC="nullsrc=s=64x48:r=24:d=1,format=yuv420p10le,geq=lum='96+80*trunc(X/8)+12*mod(N\,2)':cb=512:cr=512"
ffmpeg -f lavfi -i "$SRC" -c:v libx265 -tag:v hvc1 -crf 4 -x265-params "info=0:colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc" -color_primaries bt2020 -color_trc arib-std-b67 -colorspace bt2020nc -fflags +bitexact -flags:v +bitexact x265-hlg.mov
ffmpeg -f lavfi -i "$SRC" -c:v libx265 -tag:v hvc1 -crf 4 -x265-params "info=0:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:hdr10=1:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400" -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc -fflags +bitexact -flags:v +bitexact x265-pq.mp4
```

## Empty H.264 tail fixture

`h264-empty-nal-tail.mp4` derives from `ffmpeg-h264-aac.mp4` through a packet-copy
remux with `filter_units=remove_types=0`, followed by one independently inserted eight-byte sample:
`00 00 00 04 00 00 00 00`. The video sample table gains one size-8 sample,
one single-sample chunk at the end of `mdat`, and one duration-1 timing entry.
The valid 48 video and 95 audio packets retain the remuxed fixture's hashes
and timestamps. The regression test fixes the SHA-256 of their sorted
ffprobe CSV packet signatures, including stream, PTS, DTS, duration, size,
payload hash and audio priming metadata.
This models the invalid type-0 tail observed in a public TikTok download.

SHA-256: `a0a7d920fa80c8b091397fef9f479749a2f8d4525f68101f2e07ad19f4bb5d3a`.
