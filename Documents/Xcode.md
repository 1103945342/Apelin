# Working on a project in Xcode

A project made from a template in Luros also carries an Xcode project:

```
My Project/
  luros-project.json      the description Luros builds from
  Sources/  Resources/  Packaging/
  My Project.xcodeproj/    for a Mac
  Xcode/Support/           the extension's headers and link stubs
```

The `.xcodeproj` is written from `luros-project.json` when the project is
made. Every product becomes a native target of the kind Xcode has for it —
an application, an app extension, a dynamic library, a bundle, a command line
tool — with the project's deployment target, architectures, optimisation,
defines, header and library search paths, frameworks and bridging header.
The files each target compiles and copies are the ones the description's
globs matched at that moment, and a shared scheme is made for each target, so
`xcodebuild -scheme <target>` has something to build.

`Xcode/Support/` holds what the extension supplies and a Mac cannot see
inside Luros's extension folder: for a tweak, `substrate.h` and
`libsubstrate.tbd`. Headers are given to every target that names the
component, and the link stubs are searched with `-l`. A project that lists
both bootstraps links roothide's stubs, which find the library through
`@loader_path/.jbroot`; a rootless-only project links rootless's.

## Getting it to the Mac

A project is a git repository on `main`, from the first minute. Add a remote
and push, clone it on the Mac, and open the `.xcodeproj`. Work goes both ways
through git as usual.

After that, Xcode owns `project.pbxproj`. A file added in Xcode is added to
it; bring the file back to the device with a pull. A file added to the
project on the device is added in Xcode the way any file is — the generator
never runs again, because a second run would throw away what Xcode wrote.

## What stays on the device

- **The package.** The deb's control file, its layout, its maintainer
  scripts, or an `.ipa`'s `Payload/` — all of it comes from an Luros build.
  Xcode builds the binaries.
- **Signing.** Nothing is signed there: `CODE_SIGNING_ALLOWED` is `NO`, so
  Xcode's Run needs an Apple developer certificate and a normal device, which
  a jailbroken installation is not. Install the package Luros built, or sign
  the binary yourself (`ldid -S<entitlements> <binary>`) and copy it into the
  bootstrap.
- **`swiftModules`.** A project that vendors Swift modules — a dependency's
  sources compiled into `.swiftmodule`s — has no target for them here. A
  project built that way needs those modules added by hand.

## When the description changes

Changing a product's name, its sources, or its type in `luros-project.json`
does not change the Xcode project. Make the same change in Xcode, or generate
a fresh project beside the old one and compare.

## Where it lives

- `Packages/ApelinKit/Sources/ApelinProject/Project/XcodeProject.swift` —
  the generator, called from `ProjectStore.create`.
- `Packages/ApelinKit/Tests/ApelinProjectTests/XcodeProjectTests.swift` —
  the projects it writes, read back as property lists.
