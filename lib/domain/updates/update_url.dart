/// Returns whether [uri] is a valid, credential-free, fragment-free HTTPS URL.
bool isSafeHttpsUri(Uri uri) =>
    uri.scheme.toLowerCase() == 'https' &&
    uri.host.isNotEmpty &&
    uri.userInfo.isEmpty &&
    !uri.hasFragment;
