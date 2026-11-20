// The source of the ios-arm64e-*-binds binaries. See build.sh. No headers:
// the older linkers these are made with cannot read a current SDK's.

extern int luros_imported(const void *string);

__attribute__((visibility("default"))) int luros_fixture(void) {
    return luros_imported(__builtin___CFStringMakeConstantString("luros"));
}
