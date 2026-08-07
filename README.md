# PKGBUILDS

Here you can find the build files for VasakOS and related applications

## Build

for build a package you can use `makepkg` command

```bash
makepkg -si
```

### Build all VasakOS packages

`build-all.sh` builds every package in this repo **except Calamares**. When a
release and a `-git` variant both exist (e.g. `vasak-desktop` /
`vasak-desktop-git`), the `-git` one is preferred. Run it as a regular user:

```bash
./build-all.sh                 # build everything (keeps going on failure)
./build-all.sh -o ./out        # also copy built packages into ./out
./build-all.sh -i              # also install each package
./build-all.sh -x vasak-flare-daemon   # skip a package (repeatable)
./build-all.sh -s              # stop on the first failure
```

It prints a built-OK / failed summary at the end.

## Contributing

Pull requests are welcome. For major changes, please open an issue first to discuss what you would like to change. Please make sure to update tests as appropriate.

1. Fork it
2. Create your branch

```bash
git checkout -b feature/new-application
```

3. Commit your changes 

```bash
git commit -am 'Add some new-application'
```

4. Push to the branch

```bash
git push origin feature/new-application
```

5. Create a new Pull Request

## Contributors

<a href="https://github.com/vasak-os/PKGBUILDS/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=vasak-os/PKGBUILDS" />
</a>