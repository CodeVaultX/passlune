// Google sign-in through browser.identity.launchWebAuthFlow (lib/drive.js) with
// a "Web application" OAuth client: Firefox, and Edge, which lacks
// chrome.identity.getAuthToken. The official builds fill these in; to use your
// own Google Cloud project, see BUILDING.md.
export const webClientId = '';
export const webClientSecret = '';