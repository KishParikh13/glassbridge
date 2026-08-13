# Test samples

Two ways to validate the backend before you touch iOS:

## A. Without recording anything (fastest)

We bypass Whisper entirely with the `text_override` form field. Put any
JPEG you have lying around at `samples/scene.jpg`, then:

```bash
# Save a silent 1s wav for the audio field; it won't be used.
python3 -c "
import wave, struct
w = wave.open('samples/silence.wav','w')
w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
w.writeframes(struct.pack('<' + 'h'*16000, *([0]*16000)))
w.close()"

# Use a real photo you took (selfie, anything).
cp ~/Downloads/anything.jpg samples/scene.jpg

curl -s -X POST http://localhost:8082/ask \
  -F "audio=@samples/silence.wav" \
  -F "image=@samples/scene.jpg" \
  -F "text_override=What's in this image? Answer in one short sentence." \
  -D /tmp/headers.txt \
  --output /tmp/reply.mp3

cat /tmp/headers.txt | grep -i glassbridge
afplay /tmp/reply.mp3
```

If you hear Claude describe the image: the backend works end-to-end.

## B. With your real voice

Use macOS Voice Memos or `ffmpeg` to record 3–5s of yourself asking a
question, save as `samples/question.wav`. Then:

```bash
curl -s -X POST http://localhost:8082/ask \
  -F "audio=@samples/question.wav" \
  -F "image=@samples/scene.jpg" \
  -D /tmp/headers.txt \
  --output /tmp/reply.mp3

cat /tmp/headers.txt | grep -i glassbridge
afplay /tmp/reply.mp3
```

The `X-Glassbridge-Transcript` header URL-decodes to whatever Whisper heard.
