// Google Drive sync ("Google ile senkronize et"). The official Passlune builds
// fill these in with the OAuth clients of their Google Cloud project. They are
// empty here, so a build from this source hides Drive sync and syncs through a
// folder instead (Dropbox, OneDrive, Syncthing, ...). To use Drive sync with
// your own Google Cloud project, see GOOGLE_SETUP.md.

/// "Web application" client ID. Android uses it as serverClientId.
const googleWebClientId = '';

/// "Desktop app" client ID and secret, used by the Windows build.
const googleDesktopClientId = '';
const googleDesktopClientSecret = '';