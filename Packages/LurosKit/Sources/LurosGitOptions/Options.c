#include "LurosGitOptions.h"

// Declared here rather than read from libgit2's headers: the target then
// needs nothing of the framework to compile, and LurosGit links both.
extern int git_libgit2_opts(int option, ...);

int luros_git_set_option(int option, int value) {
    return git_libgit2_opts(option, value);
}

int luros_git_get_option(int option, int *value) {
    return git_libgit2_opts(option, value);
}
