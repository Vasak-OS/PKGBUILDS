# PKGBUILDS

Here you can find the build files for VasakOS and related applications

## Build

for build a package you can use `makepkg` command

```bash
makepkg -si
```

### Build all VasakOS packages

`build-all.sh` builds the packages in this repo that are **out of date**
It asks makepkg which files each PKGBUILD would produce
and compares them against the pacman repository staging directory — by default
`../repository-script/x86_64`. Packages already published there are skipped;
the rest are built, copied in, and the versions they replace are deleted.

When a release and a `-git` variant both exist (e.g. `vasak-desktop` /
`vasak-desktop-git`), the `-git` one is preferred. Run it as a regular user:

```bash
./build-all.sh                       # build and publish whatever changed
./build-all.sh -n                    # dry run: what would be built and removed
./build-all.sh vasak-desktop-git     # force one package, ignoring the check
./build-all.sh --adopt               # publish packages already built here
./build-all.sh -a                    # rebuild everything
./build-all.sh --no-repo             # ignore the repository, just build
./build-all.sh -o ./out              # also copy built packages into ./out
./build-all.sh -i                    # also install each package
./build-all.sh -x vasak-flare-daemon # skip a package (repeatable)
./build-all.sh -s                    # stop on the first failure
```

`./build-all.sh --help` lists every option.

Since only the changed packages are built, the `check-all.sh` pre-flight runs
only on the apps that are about to be built — against the sources makepkg
fetched, not your working copy, because that is what ends up in the package.

**An app that does not compile no longer stops the run.** That package is left
out and everything else is built; the summary lists what was skipped, and the
exit status is non-zero so nothing automated mistakes it for a clean run. The
version already published stays in place, so the repository is never left half
updated — just without that one update. Fix it and run again: only the skipped
packages get rebuilt.

Use `--strict-check` for the old behaviour (abort if anything fails the
pre-flight), or `--no-check` to skip the pre-flight and try everything.

### Checking the packages run everywhere

`check-portability.sh` reads the finished packages and fails if any of them
carries instructions no pre-2013 CPU has. `build-all.sh` checks the *sources*
pin the architecture; this is the backstop that catches what that cannot see — a
C package picking up `-march=native` from `makepkg.conf`, or a vendored binary.

```bash
./check-portability.sh                     # everything in the repository
./check-portability.sh vasak-desktop-git   # one package directory
```

`update-repo.sh` runs it between building and signing, and refuses to sign if
anything fails.

The full release — build, publish, sign the database — lives one directory
over:

```bash
../repository-script/update-repo.sh
```

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