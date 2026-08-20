# Persistent "Cast to Speaker" output device (Linux)

Copy both `.service` files to `~/.config/systemd/user/`, then:

```bash
sudo apt install pulseaudio-utils netcat-openbsd   # already present on most desktop distros
systemctl --user daemon-reload
systemctl --user enable --now cast-to-speaker-sink cast-to-speaker-stream
```

"Cast-to-Speaker" now shows up as a normal selectable output device — pick
it as default, or route a specific app to it.
