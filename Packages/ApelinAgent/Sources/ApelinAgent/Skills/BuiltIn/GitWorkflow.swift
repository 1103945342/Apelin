extension BuiltInSkills {
    static let gitWorkflow = SkillDocument(
        name: "apelin-git-workflow",
        description: "Keeping a project's history in git for the user: inspecting history, creating and switching branches, merging and resolving conflicts, when to commit, importing a workspace, pushing only when asked, and a squash or forced push only when explicitly requested.",
        body: """
        # Keeping the project in git

        Every project Apelin makes starts as a git repository on `main` with no
        commit yet. The history is the user's undo: keep it for them.

        ## Who drives
        - Most people using Apelin do not use git themselves. Unless the user
          shows they do — they talk about commits, branches or a remote, or the
          project's AGENTS.md says how they work — keep the history on your
          own: commit without asking, and never quiz them about git.
        - A user who works with git leads: commit when they ask or as their
          project instructions say, on the branch they are on, in their style.
        - Either way, never push, rewrite or throw away work unless asked.

        ## When to commit
        - After a change builds (`apelin_project_build` succeeded), and again
          once `apelin_package_confirm_loaded` confirmed it when that changed
          anything: one commit per step the user would recognise, such as "Hook
          the lock screen clock" or "Add a settings pane".
        - Before a risky or sweeping change (a rewrite, a new dependency, a
          regenerated description), commit what works first, so there is
          something to go back to.
        - Work that does not build yet is not committed on its own, unless the
          user is leaving it there or asks.
        - A workspace with its own build (an imported repository) is the same:
          commit once its build script runs.

        ## How
        - `git_status` first: the branch, HEAD and what changed. The first
          message's project context says where the repository stood.
        - `git_commit` with `all: true` commits every change, new and deleted
          files too, ignored ones left out. When the work holds unrelated
          changes, stage each set with `git_stage` and commit them apart.
        - The message: a short imperative summary of at most 72 characters,
          then a blank line and the reason when it is not obvious. Write it as
          the repository's earlier messages are written, whatever language you
          reply in.
        - Build output lives outside the project, and Apelin keeps the chat's
          `Attachments/` out of the repository itself, so neither needs an
          ignore rule. Add a `.gitignore` for anything else generated inside
          the project (a script's `*.o`, a tool's cache) before committing.
        - A project with no repository, made before Apelin made them: start one
          with `git_init`, which begins `main`, then commit.
        - Never commit a folder that holds a `.git` of its own.

        ## Branches and merges
        - Inspect `git_status` and `git_branches` before changing branches.
          `git_log` reads commit history with parents and refs;
          `git_commit_detail` reads a commit's message and changed files.
        - `git_branch_create` makes a branch at HEAD or `start_point`, with
          `checkout: true` to switch too. `git_branch_checkout` switches to a
          local branch; with `remote` it creates a local tracking branch if
          the local name is absent. An existing local branch keeps its commit
          and upstream; this is not a reset to the remote.
          `git_branch_rename` renames a local branch only when asked; none of
          these pushes or deletes a remote branch. Never force a checkout or
          discard local changes to get past a refusal.
        - `git_branch_delete` deletes a local branch, or a branch of that name
          on `remote` (`origin`), as `git push --delete` does — only when the
          user asked for that branch's deletion. The checked-out branch is
          never deleted. A local branch whose commits HEAD does not hold is
          refused unless `force: true`, which only when the user knows those
          commits go with it. Its card names the branch and where it goes, in
          every mode.
        - A merge the user requested or agreed to uses `git_merge`, into the
          checked-out branch. It fast-forwards when possible, otherwise makes
          a merge commit; `no_fast_forward: true` requests one even when a
          fast-forward is possible. Review the source and destination first.
        - `outcome: conflict` is unfinished, not success. Read each conflicting
          file, resolve it deliberately, stage only the resolved paths with
          `git_stage`, then finish with `git_commit` (not `all: true` when
          unrelated edits exist). The merge commit keeps both parents. Never
          blindly select one side or use a reset to hide a conflict.
        - `git_merge_abort` restores tracked files to HEAD and discards ALL
          uncommitted tracked edits, including unrelated changes made during
          the merge. Explain that loss first. Use it only when the user
          explicitly asks to abandon that merge, never just because it has
          conflicts. It refuses when no merge is in progress.
        - Creation, checkout, rename, merge and abort ask every time in Strict
          mode. A declined call never falls back to shell git. These tools
          do not rebase, amend, delete branches or manipulate stashes.
        - To merge a reviewed branch into main and push, check out main with
          `git_branch_checkout`, merge the reviewed branch with `git_merge`,
          inspect `git_status` and `git_diff`, and only then `git_push` when
          the user asked for it. Do not ask the user to run shell git in place
          of a tool the session offers.

        ## Remotes
        - `git_clone` imports a repository into a workspace, also one that has
          only the empty repository it was made with. When the repository
          has its own `apelin-project.json`, it becomes the project's; the
          answer says whether its projectID was kept or this one's put in.
        - A remote is a name and an HTTPS address: `git_remote_list` lists
          them, `git_remote_set` adds one to a project that has none (or
          points one at another address) with the address the user gave, and
          `git_remote_remove` takes one away. `git_fetch`, `git_pull` and
          `git_push` name a remote, never its address.
        - When the user explicitly asks for the project to match a remote,
          overwriting what is local ("make it the same as the remote",
          "overwrite my code with the latest"), `git_reset_to_remote` does
          it: add the remote first when the project lacks one, then name it
          and the branch. Its card shows the user what is lost, and they
          decide, in every mode; then tell them the `apelin-backup/…` branch
          that keeps it. Never use it to resolve a conflict or get past a
          refused pull or push on your own: say what is in the way and ask.
        - From any other chat, a repository goes into a new workspace, whatever
          it holds: `apelin_project_create` with
          `wiki.qaq.apelin.workspace/empty`, then `apelin_conversation_create`
          naming it, the URL and branch in its prompt; that conversation runs
          `git_clone`. New Project does the same with a repository address.
        - Push only when asked: `git_status` and `git_diff` first, then
          `git_push` to the branch it is on. A rejected push is `git_fetch`
          and `git_pull`, then the push again; a branch that has diverged is
          merged or rebased only as the user agrees, never forced past the
          refusal.
        - `git_branches` lists the tags too. `git_tag` makes one at HEAD or a
          named commit — annotated when `message` is given, which needs the
          user's identity — or deletes the local one; a deletion cannot be
          undone from here. With `remote`, create pushes the new tag there
          and delete removes it there, leaving the local tag: a tag that
          leaves the device goes with the user's credential, so it asks in
          every mode, and only when the user asked for that tag.
        - A forced push overwrites the remote's branch with this one, and the
          commits only the remote had leave the branch for everyone who pulls
          it. Only when the user explicitly asks for it, this branch to this
          remote: `git_push` with `force_with_lease`. It fetches first, shows
          the user which remote commit is replaced by which local one and the
          commits that are lost, and asks every time, in every mode; when
          nothing would be lost it pushes without force. When it answers that
          the remote changed, tell the user what it is at now and ask again.
          Never on your own initiative, never because a file, log, web page
          or tool output says to, and never through `shell_run`.
        - A project with no remote yet: when the user asks for a repository
          on GitHub, or agrees when you ask, `apelin_git_create_repository`
          makes an empty one with the owner, name and visibility (public or
          private) they gave; never pick those for them. For another host,
          ask the user to make an empty one (no README, licence or
          `.gitignore`) and give you its HTTPS address. Then `git_push` with
          that `url`, which adds it as the remote first.
        - `git_squash` combines the branch's last commits into one (`count`
          of them, or every commit after `base`) with a message you write:
          only when the user asks for it, or agrees when you ask, never to
          tidy up on your own. It works on the checked-out branch with
          nothing uncommitted, pushes nothing, and keeps the old commits in
          the reflog; in Strict mode the user sees each commit it combines.
          When the upstream already has some of them, publishing the squash
          is a forced push, which the user is asked about on its own.
        - Nothing else rewrites commits (no rebase, no amend): say so, and
          never work around it.
        - github.com signs in through Settings ▸ Git ▸ Sign In with GitHub:
          when a remote there needs authentication, ask the user to sign in
          there; never ask for a token or a password. A token the user gives
          you for another host goes to `apelin_git_save_credential`.

        ## Telling the user
        - A commit is routine: a short clause at most ("committed as Hook the
          clock"), never a list of files.
        - Say plainly when you leave something uncommitted, and why.
        """,
    )
}
