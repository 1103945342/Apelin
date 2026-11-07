extension BuiltInSkills {
    static let ipaDevelopment = SkillDocument(
        name: "apelin-ipa-development",
        description: "A project whose build hands back an .ipa instead of a deb: creating it from an app template with output_format ipa, what the description and entitlements carry, the build, sharing it from Distribute… for another certificate, installing it on this device and removing it again, and testing the app it made.",
        body: """
        # IPA projects

        An `ipa` project builds one app and hands back `Payload/<Name>.app/` zipped:
        the bytes the `sign` step left, signed again for a certificate when someone
        installs it elsewhere. It installs nothing as a package, and a package
        manager never sees it. Everything else about the project — products,
        configurations, steps — is an app project's (apelin-project-description).

        ## Creating one
        - `apelin_project_create` with an app template (`wiki.qaq.apelin.dev.app/…`)
          and `output_format: "ipa"`. Never the empty workspace, and never a deb
          project whose `format` is edited afterwards: the create path writes the
          whole description in one go, and its packaging baseline is that
          description.
        - The New Project screen offers the same choice under **Output** while an
          app template is ticked, so the agent and the screen make the same
          project.
        - `output_format` is an app template's alone. A workspace builds what its
          script writes (apelin-external-build); a tweak, a command line tool and
          a preference bundle are deb projects.

        ## What the create path writes
        - `package.format: "ipa"` with `kind: "app"` and exactly one app
          product — the two things the check's ipa rule enforces — and, as the
          create path writes it, `layout: []` and no `depends`,
          `conflicts`, `breaks`, `replaces`, `provides`, `recommends`,
          `suggests`, `maintainerScripts` or `tweakFilter`: an `.ipa` reads none
          of them, so a description that carries one says something the build
          never hands back. Never add one by hand.
        - `arm64` for both bootstraps: an app that runs on ordinary iOS, not
          `arm64e`.
        - The entitlements are a container app's: `get-task-allow` and nothing
          else. **No `platform-application`, no `no-sandbox`** — those belong to an
          app installed into a bootstrap for the jailbreak, and the same `.ipa`
          must install on a device without one. Should the user actually want the
          jailbroken app, say what that costs and keep the project a deb app
          instead, where those entitlements are the template's.
        - The code is ordinary UIKit and Foundation. Private frameworks, a
          bootstrap's headers and anything reading another app's container are
          refused by the App Store and by a signed install elsewhere: leave them
          out of an ipa project.

        ## Build
        - `apelin_project_build` compiles, links, makes the dSYM, signs with the
          project's entitlements and only then writes the `.ipa`, so the file it
          records with `format: "ipa"` carries the bytes that were signed.
        - The artifact is a `package` artifact like a deb's, with an `id` and a
          `digest`. It is never a deb: do not rename it, do not wrap it into a
          package of your own, and do not copy it into the project.
        - A release build of an ipa project goes to the user only through
          Distribute… ▸ Share `.ipa`. `apelin_package_publish` takes debs;
          never publish an ipa to a package repository, and never write one into
          `debs/`.

        ## Installing it on this device
        - `apelin_package_install` takes the ipa artifact's `id` and `digest`. The
          host checks the digest against the record, unpacks the `.ipa` in private
          staging, refuses a `com.apple.` bundle id, copies the bundle to
          `<install root>/Applications`, signs every Mach-O with `ldid` using the
          entitlements it carries and registers it with `uicache -p`. It then
          appears in `apelin_package_list` with an `installationID`.
        - `apelin_package_remove` takes it off: `uicache -u`, then the bundle goes.
        - Never install, uninstall or register it another way: not `icli app
          install`, not `icli pkg install`, not `dpkg`, not `apt`, and no
          `uicache` of your own.
        - A bundle id is permanent once the app is installed (the
          apelin-packaging-and-install skill's Package identity): a new one is
          another app beside it, and the old one stays until it is removed. Settle
          it with the user before the first install. A second install of the same
          project replaces that installation; the same bundle id installed from
          another project is refused, and so is a bundle already sitting where
          this one asks to go — remove it first, never delete it by hand.
        - Installing needs no package dependency and no maintainer script: an
          app's data folders are made by the system on first launch, in its own
          container.

        ## Testing the app it made
        - Launch it with `icli` or the screen tools and read what it draws; a blank
          template page is enough to prove it installed and runs. A log line the
          app writes with `os_log` comes back from `apelin_log_read` with the
          app's process name.
        - A crash is read before anything is changed (apelin-crash-triage). Keep
          the build's dSYM.
        - The whole loop — build, install, launch, remove — is run with
          `apelin_project_build`, `apelin_package_install`,
          `apelin_package_remove`: nothing about it needs the terminal.
        """,
    )
}
