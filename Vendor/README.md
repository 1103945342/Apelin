# Bundled tools

Luros carries the device tools it cannot work without, so its package depends
on no package for them:

| File | From | Version | SHA-256 |
|---|---|---|---|
| `bin/icli` | `com.icli.icli` | 0.11.0 | `728f350e54a0101793506e4771342dc68cde2ee5e4f6cb9579b5293d20b87cfb` |
| `libexec/irisind` | `wiki.qaq.irisin` | 5.1.8 | `b42392b8709831e6846342ae4dc0b49633757fb39b56d0ab604910f5b087d293` |
| `libexec/irisin-install` | `wiki.qaq.irisin` | 5.1.8 | `1fd12cc983903ebb7dded8dd0cb448da9d127a2607740a4bd3efd7ad67ede5f9` |

`irisind` is only the front: it takes a transaction and runs the install
through `/usr/libexec/irisin-install`, the helper at that exact path. A daemon
without it answers every transaction with `helperUnreachable` and exit 69, and
the client asking about the transaction afterwards is told Irisin does not
know it — the install fails without ever naming the helper. A device that had
Irisin and lost it keeps a working `irisind` only if this second file is
carried and put back beside it.

`Scripts/package-deb.sh` copies them into `Luros.app/Vendor/`, so the
installed app finds them beside itself:

- `Luros.app/Vendor/bin` goes on the `PATH` every run gets
  (`DevelopmentEnvironment.searchPath`), behind the bootstrap's own
  directories, so an `icli` the device installed still wins.
- `Luros.app/Vendor/libexec/irisind` is the daemon the app needs to install a
  package, register an app or remove either. `postinst` registers it under
  the label `com.fluoxetine.luros.irisind` with the Mach service name `irisind`
  serves, and only when no Irisin of its own is installed: a device that has
  the real package keeps its daemon, and this copy is never started beside it.

Both commands link nothing but system libraries and Swift, so a copy is
enough; neither reads a resource from the rest of its original package.

## Updating

Replace the file, then update the version and digest in this table. Take the
binaries from a device that has the package installed:

    cp /usr/bin/icli Vendor/bin/icli
    cp /usr/libexec/irisind Vendor/libexec/irisind
    chmod 0755 Vendor/bin/icli Vendor/libexec/irisind
    shasum -a 256 Vendor/bin/icli Vendor/libexec/irisind

The copies are committed rather than fetched at build time because the
package is built on macOS, where neither package is installed, and a build
that reaches GitHub for them would fail offline.

## Licensing

`icli` is MIT, © OwnGoal Studio, and its licence ships beside it in the
package at `/usr/share/doc/icli/LICENSE`.

`irisind` comes from Irisin. Its licence is not stated in the installed
package, so redistribution of this copy should be confirmed with its author
before the package is published outside this device.
