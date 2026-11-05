# Browser navigation boundaries

The Browser place keeps ordinary website windows in its tab strip. Both clicked
`target="_blank"` links and top-level JavaScript `window.open(url)` calls route
through `BrowserLinkTabRequest`; the Zodiac PRO 5.5 configurator uses the latter.
Clicked links always open as tabs, even to login pages such as HeyReach's
`/account/login`. Embedded script popups and script-opened authentication
endpoints retain WebKit's supplied configuration and opener for sign-in callbacks. Blank script windows
also retain their opener. These authentication exceptions still use native windows.

Gmail and Google Calendar account links reuse the current tab only when the
source and destination are the same product and the destination identifies an
account (`/mail/u/...` or `/calendar/u/...`). Google AccountChooser links also
qualify when their decoded `continue` URL matches that product. Google app
launcher links to another product keep normal tab behavior.

Native new-tab URLs (`otto:` and legacy `muse:`) never load in WebKit. The
navigation delegate cancels them, including back/forward swipe requests. Toolbar
history and reported back/forward availability exclude these URLs and
`about:blank`. The native new-tab surface remains available through New Tab.

Pinning is available through the visible pin button beside the address/tabs and
through each tab's context menu. Clicking an existing pin toggles it off. Saved
shortcuts are horizontally scrollable so sites beyond the first six remain
reachable. The existing pinned-site persistence is retained.

Regression coverage lives in `BrowserPopupTests`; `BrowserChromeTests` can export
native chrome previews with `OTTO_BROWSER_CHROME_SNAPSHOTS`. A real WebKit fixture
checks JavaScript popup delivery to the tab owner and cancellation of legacy
internal navigation. Live signed-in Google account switching requires a manual
check in the updated app; tests use URL routing without personal accounts.

## Conversation browser ownership

Each bot or session owns its drawer browser node. Both `browser.open` and
`browser.open_tab` without a `nodeID` reuse that conversation's browser and add
page tabs. They never fall back to the Browser place or another conversation.
An explicit `nodeID` can still target a page the person asked an agent to work
with (including the Browser place's helper), but it does not attach that browser
to the agent's drawer or change its owner. Drawer open requests, rendering and
closing all check the persisted owner.

The drawer exposes its browser's persisted page tabs below the address bar,
with add, switch, close and all-tabs controls. These are distinct from the work
surface tabs (Browser, terminal, files). The drawer has no Open in Browser action.
Website login storage remains shared; browser node ownership isolates tabs and
navigation, not website credentials.

## External app callbacks

Top-level app links, including OAuth callbacks, are handed to macOS Launch
Services when a receiving application is registered. The same routing applies to
sign-in popups. HTTP(S), native Otto/Muse new-tab URLs, local files and script/data
URLs are never handed off through this route. Unknown app schemes and failed
launches keep the normal navigation failure rather than claiming sign-in worked.

WebKit can reject an HTTP redirect to an app scheme before navigation policy
runs, reporting “Redirection to URL with a scheme that is not HTTP(S)”. The
browser also handles that specific failure using its failing destination URL.
It does not reload or replay the authorization request, and does not log the
callback URL or its one-time code. Successful handoff clears the page-load error;
it does not assert that the receiving app completed authentication.

`BrowserExternalNavigationTests` cover routing and error recovery with an injected
app launcher. `BrowserPopupTests` exercises a real local HTTP 302 redirect through
WebKit without launching another app. A live WHOOP authorization remains a manual
check with the updated build and the intended callback app installed.
