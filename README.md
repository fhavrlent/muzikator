# muzikator

Rip an audio CD → encode FLAC → tag via MusicBrainz → fetch lyrics → rsync to a server.

## Required tools

### macOS (Homebrew)

```sh
brew install libcdio-paranoia chromaprint flac rsync pipx
pipx install 'beets[chroma,fetchart]'
```

`python3` ships with macOS.

### Linux (Debian / Ubuntu)

```sh
sudo apt install libcdio-paranoia libchromaprint-tools flac rsync python3 python3-pip
pip3 install --user 'beets[chroma,fetchart]'
```

## Run

Make the script executable once, then invoke it:

```sh
chmod +x rip-cd.example.sh
./rip-cd.example.sh --help
```

### Local-only (no server upload)

With no remote configured (or when using `--no-upload`), the pipeline writes
into a temp workspace that gets **wiped on exit**. To keep the files you must
also pass `--output-dir`:

```sh
./rip-cd.example.sh --no-upload --output-dir ~/Music/muzikator
```
