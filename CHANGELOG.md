# Changelog

All notable changes to Otto (called Muse before 0.2.0) are documented here. Each released version's section is
published verbatim as the in-app update notes and on the download site, so write for users:
lead with what they can now do, not how it was implemented.

## Unreleased

### New

- **Long Otto Harness chats compact themselves to fit the model you picked.** When a session or bot chat reaches about 60% of the model's context window, Otto summarises the older messages and carries on from that summary plus the recent ones, so long chats stop growing more expensive with every message. The window comes from the provider's own model list where it has one (Anthropic, OpenRouter, Groq, Mistral, Moonshot, LM Studio, vLLM), so a 32k local model compacts early and a 1M-token Claude model compacts late. If a provider still rejects a message as too long, Otto compacts and retries once and remembers the smaller limit. The chat shows a note when this happens (issue #45).
- **Skills: one library every bot, team and session can use.** Chat → Skills shows every skill on your Mac in one list: Otto's own, plus the ones Claude Code, Claude plugins, Codex, Hermes and OpenCode already have, with where each lives and how often it was used. Turn on **All agents** for any of them, or write a new one, and every bot, team and session can use it whichever harness it runs on; narrow it to particular bots if you like. Agents see a one-line list of their skills and load a skill's full instructions only when a task needs it, so a big library costs few tokens (issue #43).

### Fixed

- **Spreadsheet FIND and SEARCH no longer crash on a start just past the text.** `FIND("ld", A1, 12)` on an 11-character cell now answers #VALUE!, as Excel does, instead of stopping the app. Thanks to Sukhpal Gill (onlinegill) for PR #60.
- **Telegram albums interrupted mid-send are let go.** Stopping or reconnecting Telegram while an album was still arriving left its photos held in memory for the rest of the session. Thanks to Sukhpal Gill (onlinegill) for PR #61.
- **Home updates show what you asked a bot to do.** A finished bot's update could start with Otto's internal "[OTTO CONTEXT PROMPT …]" text instead of your request.

## 0.2.15 — 2026-11-04

### New

- **Agents hear back when their background work finishes.** When a session or bot starts another agent or a long command and ends its turn, Otto messages it when that work is done, so it can carry on or tell you the result without you checking.
- **Telegram replies read like texts.** Bots know a message came from Telegram and keep replies short and plain. Diagrams, tables and detail sections are turned into plain text on Telegram and iMessage.
- **Telegram sends late answers.** If a bot takes more than two minutes, Telegram says it's still working and sends the answer to the same chat when it's done, instead of telling you to check your Mac.
- **Otto spots stuck agents.** Home lists an agent that has made no progress for 15 minutes or keeps repeating the same step, with Open chat and Stop it, and reminds you when an agent has waited 20 minutes for your OK. An automation that fails on a network blip, timeout or rate limit is retried once after two minutes.

### Changed

- **Messages you queue for a busy agent arrive together.** Several messages typed while an agent works are sent as one message when it is free, instead of one turn each.

### Fixed

- Sending from Home no longer stays stuck when a Git change snapshot stalls. Snapshots have a two-second budget, and Home opens the destination chat as soon as it is created.
- **Editing an automation's schedule takes effect straight away.** Before, the old schedule's next run still happened once (or until Otto restarted).
- **Shell helpers run their command again.** A Shell agent started by a bot or session failed straight away with "parse error near ')'" because Otto wrapped its command in chat context. It now runs exactly what it was given.
- **Agent tool calls no longer stall when many arrive at once.** Otto's control socket, which every agent, `ottoctl` and `otto-mcp` call goes through, waited for replies on a small shared thread pool. A burst of calls could hold every thread until the calls timed out after 10 seconds. Each call and each incoming connection now waits on its own thread. The control socket also builds on Linux. Thanks to Justin Philip Flores (GospelNerd) for PR #50.
- **A signed-out agent shows as stopped instead of nagging you.** When Claude Code's sign-in expires ("Failed to authenticate: OAuth session expired"), Otto now marks the run as failed instead of leaving it "working", and its old "Needs you" entry clears instead of reappearing (issue #54). Thanks to Sukhpal Gill (onlinegill) for PR #56.
- **Usage-limit waits use the full reset time.** "Try again in 2 hours and 15 minutes" no longer retries 15 minutes early, and weekly limits that say "in 3 days" now offer Wait and retry. Thanks to Sukhpal Gill for PR #59.
- **Automation schedules like `5/15` are accepted.** Cron steps that start from a single value now run at 5, 20, 35 and 50 past the hour instead of being rejected as invalid. Thanks to Sukhpal Gill for PR #55.
- **An automation with an impossible time can be saved again.** A schedule such as `5 24 * * *` (set by an agent) showed as "Every day at 24:05" and blocked every save. It now shows as a custom schedule. Thanks to Sukhpal Gill for PR #58.

## 0.2.14 — 2026-11-02

### New

- **New session asks for an API key before starting Otto Harness.** Pick Otto's own harness with no vendor key or local server saved and a sheet asks for one, then starts the session for you. If a session cannot start, Otto now says why instead of doing nothing. In New session the harness is listed as "Otto".

### Fixed

- **Telegram messages are no longer lost while a bot is busy.** Send a second message while your bot is still working and Otto replies "Queued behind the current task" and delivers it, in order, when the bot is free. A message the bot genuinely cannot take is bounced with its text so you can send it again (issue #41).
- **Reach any of your bots from Telegram.** `/bots` now says which saved bots are not yet allowed for Telegram and where to allow them. `/use` and `/bot` accept a bot's name or a unique start of its handle, without the `@`, and a message that starts with `@handle` goes to that bot once. Ordinary messages that merely mention someone are untouched (issue #40).
- **Telegram voice notes transcribe again on Parakeet.** afconvert writes an extended WAV header that the Parakeet engine refused ("exited with status 255"); Otto now rewrites the clip to plain PCM first. If an engine still fails, the reply is one short line with the real reason instead of a wall of configuration, and the full detail goes to Console (issue #36).
- **Voice no longer shows "The terminal transport is closed".** When an agent's terminal closes just as you dictate or speak a command, Otto waits for the agent to settle and continues, and the Voice row shows short plain wording such as "That agent had already stopped. Try again." Spoken approvals are never turned into new prompts (issue #46).
- **Browser shows when you have more tabs than fit.** The tab row fades at its edges, the active tab is scrolled into view, and a chevron after the tabs lists every open tab (issue #38).
- **Otto Harness works with any stored key.** A bot with no model chosen uses your OpenAI key, then a configured local server, then the first other provider with a stored key (OpenRouter, DeepSeek, Mistral, Groq, Gemini, Moonshot) instead of failing with "OpenAI API key is missing". Settings → Models shows whether the Harness runtime is ready, and the bot and agent sheets say why a harness is unavailable (issue #48).

## 0.2.13 — 2026-10-30

### New

- **Approve, comment on or reject an automation's draft on Home.** An automation can stop and put its draft, such as a post or a reply, under For your review on Home. Approve it and the next step runs; comment and the agent revises it; reject it and nothing happens. Turn it on for a step in the automation editor, including steps in advanced flows.
- **Send photos and videos to your bots from Telegram.** Photos, videos, round video notes, GIFs and image or video files sent to Otto's Telegram bot now reach the chat's bot, with your caption as the message. An album arrives as one message. Videos are kept on your Mac, the bot gets still frames from them, and when on-device speech is set up it also gets what is said. Start a caption with `/bot @handle` to send it to one bot. Files over Telegram's 20 MB bot limit are refused with a note (issue #27).
- **Telegram voice notes and approvals from your phone.** Voice notes are transcribed on your Mac and sent to the bot. Connectors → Telegram → Approvals (off by default) sends tool approvals to Telegram with Approve and Deny buttons; website account approvals still stay on the Mac. Contributed by onlinegill (issue #29).
- **Talk to several bots from one Telegram bot.** Allow them in Connectors → Telegram, then pick one with `/use @handle` or message one with `/bot @handle …`. Contributed by onlinegill (issue #28).
- **A Connectors page with per-bot access, Email (SMTP) and Google Calendar.** Settings → Connectors shows each connector as a tile, and each has its own list of bots allowed to use it. Bots can send email through your SMTP server and read or add Calendar events; sending and creating always ask you first. Otto Harness also runs DeepSeek, Mistral, Groq, Google Gemini and OpenRouter models, and there's a new light theme, Daylight. Contributed by onlinegill.
- **Reply to email in its thread, approving the exact message.** The approval card shows the recipient, subject and whole body, and says when a reply isn't going to the original sender. Contributed by onlinegill.
- **Whistle on-device speech.** A 17 MB speech engine by Cactus Compute you can download in Voice settings after agreeing to its license. Command and Dictate become hold-to-talk in Push to Talk mode. Contributed by onlinegill.
- **Back up and restore Otto's setup.** Settings → Backup saves your bots, automations, connector choices and preferences to one file, without passwords or sign-ins. Restoring pauses automations and never raises a bot's permissions. Contributed by onlinegill.
- **Time and tokens for each reply, and Clear chat.** Hover a reply to see how long the turn took and its tokens. Right-click a session or bot and choose Clear chat… to start its conversation afresh. Contributed by onlinegill.
- **Sessions in a project start in its repository.** Claude Code and Codex sessions in a project with a source folder start there, so the repo's `CLAUDE.md`, `.claude/` skills and `AGENTS.md` apply. Contributed by onlinegill (issue #24).
- **Faster local models, and Fetch models.** Otto Harness requests are encoded the same way every time, so local servers reuse the prompt instead of re-reading it on every tool step. Settings → Models → Local can list the server's models. Contributed by onlinegill.

## 0.2.12 — 2026-10-29

### New

- **Join the Otto community on Discord.** There's a Discord button beside Send feedback in the Chat sidebar, a "Join the Otto community" card in the welcome flow, a Getting started item on Home that ticks once you've opened it, and a command palette entry. Release news, questions and what other people are building live there: https://discord.gg/qZKACfT7Hc
- **Rename a session.** Right-click a session in the Sessions sidebar (or use the pencil that appears when you hover it) and give it a name that says what it's about, such as the business or project you're working on in that chat. The bot, its history and your other sessions stay as they are, and the name survives a restart. Contributed by onlinegill (issue #17).
- **Settings has a sidebar, and a Connectors page.** Every Settings page is now reachable from a list on the left; with the old row of tabs, the ones that didn't fit (Cloud and Mobile) couldn't be opened. Messaging (iMessage via Photon) and Mobile pairing now live together under Settings → Connectors, beside a new Telegram connector. Contributed by onlinegill.
- **Talk to one of your Otto bots from Telegram.** In Settings → Connectors → Telegram, paste a bot token from BotFather (it goes in your Mac's Keychain), pair your own Telegram chat with a one-time code that you approve on the Mac, and choose the one saved Otto bot Telegram may message. Messages from that chat go to the bot and its reply comes back; approvals and permission prompts stay in Otto on the Mac, and nothing sent from Telegram can grant them. A group can be approved too, limited to the member who paired it. Contributed by onlinegill.
- **Local models are easier to set up.** Pasting a bare address such as `192.168.1.20:8000/v1` works, Tailscale addresses (100.64.0.0/10) are accepted over plain HTTP, and a saved local model shows in the bot's model picker straight away, with a shortcut in the bot editor to add or edit it. A bot whose older provider session file has gone now starts a fresh one instead of failing every prompt; its conversation is kept. Contributed by onlinegill.
- **Pi is a harness you can run agents and bots on.** Pi (pi.dev) is a small open-source coding agent that works with whichever model providers you sign into. Install it with `npm install -g @earendil-works/pi-coding-agent`, run `pi` once in Terminal and sign in with `/login`, and it appears beside Claude Code, Codex and the others when you start a session, hire a bot or build an automation. Otto reads Pi's live model list, streams its work into the chat, resumes sessions, and gives it Otto's tools through a `.pi/mcp.json` in the workspace. Pi has no approval prompts of its own, so Read only limits it to inspection tools, while Workspace and Unrestricted run with Pi's normal tools.

### Fixes

- **Unrestricted agents no longer wait for browser click approvals.** With an agent in Unrestricted (bypass) mode, clicking in the Otto browser still queued an approval card that nobody needed to answer. Bypass now covers browser clicks as well as the provider's own tool permissions, from the first run and when you change the mode mid-session; turning bypass off brings the approvals back. Account access in the browser still asks every time.
- **Otto no longer counts a second running copy as a crash.** Opening Otto while it was already running, or a helper starting a session while the app was up, was recorded in diagnostics as an abnormal exit. The session marker now names its process, and only a marker left by a process that has gone counts as a crash. Reported with the fix shape by mattabate (issue #23).
- **Builds with Xcode 26.5.** One expression in the welcome view took the Swift 6.3.2 compiler too long to type-check. Contributed by pat-dubois.

## 0.2.11 — 2026-10-28

### New

- **Run Otto Harness bots on a local model.** In Settings → Models choose "Local (OpenAI compatible)" and point Otto at Ollama, LM Studio, llama.cpp, vLLM or any server that speaks the OpenAI Chat Completions API. The API key is optional and stays in Otto's secure credential store; plain HTTP is accepted only for this Mac and private-network addresses. Contributed by onlinegill.
- **Android companion app, as source.** `Apps/OttoAndroidApp` is a native Android app that pairs with your Mac over a private HTTPS address and shows your sessions and bots. It is built from source or from the "Android companion APK" GitHub workflow; it is not part of the Mac download. Contributed by onlinegill.

## 0.2.10 — 2026-10-28

### Fixes

- **Otto opens on Macs with no working audio output.** Otto set up its voice playback audio while launching, and on a Mac whose speakers or output device were missing or reported an unusable format the app closed before its first window appeared. Voice audio is now set up only when you first use voice, and any audio problem shows as a voice error instead of stopping Otto from opening.

## 0.2.9 — 2026-10-27

### Fixes

- **The sidebar and thinking steps look as they did before 0.2.8.** Version 0.2.8 put a dark tint behind the sidebar and a box around an agent's thinking and tool steps on themes with artwork. That changed the look of those themes, so it's been removed. The terminal and header readability fixes from 0.2.8 are unchanged.

## 0.2.8 — 2026-10-27

### Fixes

- **Approval requests stay on screen until you answer them.** In Ask to approve mode, the approval card could flash up and vanish while the agent kept waiting, leaving it stuck. It now stays until you click Approve or Deny, for chats and bots alike, and the agent carries on as soon as you do. Questions an agent asks you stay put the same way.
- **No more approval cards that can't be answered.** An agent's own message that happened to mention an approval could show up as a card where Approve did nothing. Those false cards no longer appear, and if one ever does, Approve or Deny now clears it.
- **Text is readable on every theme.** Terminal output from agents is adjusted to stay readable against your theme, so white text on light themes and black text on dark ones no longer disappear. The sidebar, activity notes and tool steps get a soft backing over theme artwork, and header icons and buttons hold their contrast too.

### New

- **Rename, move or delete a space.** Open the space menu and choose Manage spaces to rename a space, point it at a different folder, or delete it. Deleting moves Otto's own data for that space to the Trash and never touches your files. You can't delete or move the space you're in, so switch to another one first.

## 0.2.7 — 2026-10-26

### Fixes

- **Otto opens on macOS 15 again.** Otto 0.2.6 closed straight away at launch on macOS Sequoia because a system library it needs wasn't included in the download. It's now bundled with the app, and release checks catch any library that's missing.

## 0.2.6 — 2026-10-26

### Fixes

- **Log in links open in a Browser tab.** Clicking a website's "Log in" link (such as HeyReach's) now opens the login page as a tab inside Otto instead of a separate window. Sign-in windows that a site opens itself, such as "Continue with Google", still open separately so they can finish signing you in.

## 0.2.5 — 2026-10-26

### New

- **Switch spaces with Option–Tab.** Hold Option and tap Tab to cycle through your recently used spaces, then release Option to switch. Tap once to return to your previous space, or add Shift to cycle backwards. The switcher shows each space’s icon and name; Escape cancels.
- **Keep work running as you switch.** The keyboard switcher uses Otto’s existing space navigation, keeping running agents, drafts and each space’s state in place. The shortcuts are listed in Settings → Shortcuts.

## 0.2.4 — 2026-10-26

### New

- **See which account is signed in.** Provider accounts show their signed-in identity, making it easier to choose the right account for agents and automations.
- **Paste images into Home.** Add screenshots and other images directly to the Home message box, with attachment previews before you send.

### Changes

- **Fresh spaces start clean,** without sample chats or demo sessions.
- **Routine commands stay out of your tabs.** Background agent commands no longer add terminal tabs to Chat's work drawer. Open a terminal explicitly when you want to see it; commands waiting for your input remain easy to find.
- **Pin your favourite sites more easily.** The Browser now has a visible pin/unpin button, and saved shortcuts scroll so every pinned site stays reachable.

### Fixes

- **More website buttons open in Browser tabs.** JavaScript buttons such as Zodiac's boat configurator now open a tab inside Otto. Sign-in windows keep the connection they need to complete authentication.
- **Google account switches stay in the current tab.** Switching between Gmail accounts or between Calendar accounts reuses that product's tab. Opening a different Google app still opens a separate tab.
- **Back navigation blocks old start-page URLs.** The Browser rejects legacy Muse start-page addresses during history navigation and skips internal pages when using Back or Forward.

## 0.2.3 — 2026-10-23

### New

- **A calmer place to start.** A new chat now opens on a quiet welcome: a small Otto who follows your cursor and blinks, a greeting for the time of day, the message box in the middle of the screen, and a few suggestions (Brief me on today, Draft a doc, Research a website, Automate something). In a code project you get coding suggestions instead. It scales with your window, and once you send a message the chat goes back to normal.
- **Your bots are part of Otto's family.** Bots now look like Otto: his shape in their own colour, wearing one accessory for their job (glasses, headset, hard hat, beret or antenna). Their eyes show what they're up to: glancing up while working, crossed when something went wrong and closed when offline. Pick a different look in the bot editor; photos and emoji you chose yourself are kept.
- **Bring a bot into any chat.** The new-chat screen shows your bots under "Bring in". Hover to see who's who, and click one to @mention it.
- **Videos go fullscreen in the Browser,** and file upload buttons on websites now open a file picker.

### Changes

- **Switching spaces keeps everything running.** Moving between your spaces no longer restarts Otto: agents keep working, and drafts stay where you left them.
- **Terminals live in the work drawer.** Agent and bot terminals sit in the panel on the right of Chat instead of a separate page, and the drawer only opens when you choose to look.
- **Links that open a new window now open as a Browser tab** inside Otto, instead of in another browser.
- **"Always allow" applies straight away.** Choosing Always allow on an approval now covers the run that's already going, and is remembered for that bot.

### Fixes

- **Bots no longer open blank.** If a bot's conversation lost its place, Otto now reopens the saved conversation instead of an empty chat.
- **Fixed a rare freeze** when waiting work was cancelled.

## 0.2.2 — 2026-10-21

### New

- **Otto on your screen.** Turn on Settings › Otto on Screen and Otto stays with you over every app. He strolls along the top of the Dock, you can pick him up and drop him anywhere (even on top of a window, where he'll walk along and ride with it), and he naps when nothing's happening. Click him, or press ⌥⌘O from any app, to ask a quick question, ask about what's on your screen, or jump back to your last chat. Answers come back in his speech bubble and are kept in Chat. He tells you when work finishes, fails or needs your approval, with Approve and Deny right there, instead of the usual banners. He's off unless you turn him on.
- **Send feedback from inside Otto.** Help › Send Feedback… (or the speech-bubble button in the Chat sidebar) reports a bug or an idea, with an optional screenshot of Otto's window. Reports are posted publicly on Otto's GitHub, and the form says so before you send.
- **Terminals you can actually use.** When an agent opens a terminal, it now shows up in Chat where you can see it and type into it, and Otto tells you when one is waiting for your input.
- **See how your memory connects.** Memory opens on a map of what Otto remembers and how it links together: people, projects, tags and sources. Search, filter, zoom and pan with your trackpad or mouse.
- **Browser passwords.** The Browser can save sign-ins to your macOS Keychain and fill them in next time.
- **Browser history and familiar shortcuts.** The address bar suggests pages you've visited before, and the usual shortcuts work: ⌘T new tab, ⇧⌘T reopen closed tab, ⌘L address bar, ⌃Tab next tab, ⌘[ and ⌘] back and forward. ⌘B (or ⇧⌘B from anywhere) takes you to the Browser, while ⌘B still makes text bold when you're editing a document.

### Changes

- **A tidier command palette.** ⌘F now focuses on getting around Otto as it is today.
- **Marketplace is hidden for now** while it's finished. Your existing connections keep working.

### Fixes

- **Missing chats after the rename are back.** If some sessions, such as dashboard updates, went missing after Muse became Otto, Otto now brings their links back the next time it opens, without touching anything you already have.

## 0.2.1 — 2026-10-21

### Fixes

- **Messaging works again on macOS 27.** On macOS 27, Otto could save its iMessage connection in a way the system then refused to let it read back, so messaging stopped starting. It now saves normally. If your messaging was affected, open Settings › Messaging and pair again; the old file is kept aside, not deleted.

## 0.2.0 — 2026-10-20

### Muse is now Otto

- **Same app, new name.** Muse is now called Otto, with a new icon and a new home at openotto.io. Everything you had comes with you: chats, bots, memory, automations, documents and settings move across automatically the first time Otto opens. The app also renames itself from Muse to Otto in your Applications folder.
- **macOS will ask for permissions once more.** Because the app has a new name, macOS treats it as new and asks again for the microphone, screen recording, notifications and access to saved sign-ins. Choose Allow (or Always Allow for sign-ins) and you won't be asked again.
- **Your iPhone app needs pairing again.** The phone app is also called Otto now: install it again and pair it with your Mac.
- **Otto is open source.** The code is public on GitHub under the Apache 2.0 licence.

### New

- **A friendlier Browser new tab.** New tabs open on Otto with one box to ask a question or search, and you can pin and unpin your favourite sites.

### Changes

- **Canvas has been retired.** The spatial Canvas, already hidden under Labs, has been removed. Home and Chat are the app. Nothing you made there is lost: sessions from every canvas are still in Chat.

### Fixes

- **Browser confirmations no longer hang.** A confirmation that goes unanswered now times out cleanly instead of stalling the agent.

## 0.1.59 — 2026-10-19

### New

- **Stay signed in when you switch browsers.** Importing from Dia, Chrome, Arc, Comet, Brave, Edge or Vivaldi now brings your sign-ins across as well as your bookmarks, so your sites open already signed in. macOS asks once per browser; choose Always Allow. Passwords are not copied, and your other browser is left untouched. Profiles now show their real names.
- **Search OpenCode models.** OpenCode's model menu now has a search box, lists the newest models first and hides deprecated ones.

### Fixes

- **No more "no application set to open muse://start" alert.** Opening Browser or a new tab no longer pops up a macOS dialog.

## 0.1.58 — 2026-10-19

### New

- **Browser in Chat.** Browser now sits next to Documents in Chat's sidebar, with tabs, bookmarks and Ask AI (⌘J) for the page you're on. Browsers inside session work panels have a slim bar with "Open in Browser", and you can see when an agent is reading or using a page.

### Fixes

- **Muse no longer loses your workspace when it can't read it.** If a newer Muse (such as a development build) saved your workspace, this version used to start empty and then save over your sessions. Unknown settings now fall back to defaults. If the workspace still can't be read, Muse keeps a copy, leaves the original untouched and tells you what happened.

## 0.1.57 — 2026-10-18

### Improvements

- **Faster typing in long chats.** Typing in a bot or session chat no longer slows down as the conversation grows. Earlier messages are left alone while you type, and unsent drafts save once you pause instead of on every keystroke.

### Fixes

- **“Show earlier items” shows the real count.** The button above long conversations now says how many earlier items it will load.

## 0.1.56 — 2026-10-15

### New

- **Know when work finishes.** Muse now shows native macOS notifications when a bot or session finishes or fails. Click a notification to open its conversation. Notifications are on by default; allow them when macOS asks.
- **Choose your notifications.** Settings → Notifications lets you turn alerts on or off for bots and sessions and optionally enable sound. Muse stays quiet while you are viewing the conversation, and delegated subtasks do not create extra alerts.

## 0.1.55 — 2026-10-15

### Fixes

- **Find your agents’ documents.** Agents now put documents in Documents and provide file links in Chat for Markdown files, instead of directing you to Canvas.
- **Export your latest spreadsheet edits.** Excel and Google upload exports include the cell you are still typing and keep every workbook tab. Saving an open tab also preserves tabs an agent added while you were editing.
- **No stale export after a failed save.** Document and spreadsheet exports now stop and show the error if your latest changes cannot be saved.

### Improvements

- **Clearer Google export.** “Open in Google…” is now “Prepare upload to Google…”. It identifies the new file to upload to Drive; it does not automatically sync or update an existing Google file. Export the whole workbook as Excel to upload all its tabs together.

## 0.1.54 — 2026-10-14

### New

- **Edit bots completely.** Right-click a bot → Edit bot to change anything you set when hiring it: name, responsibility, face, icon or photo, colour, shape, harness, account, model, reasoning, permissions and instructions. Open chats pick up the changes straight away. Switching harness starts a fresh chat, and the bot keeps its memory and notes.
- **Edit teams completely.** Right-click a team → Edit team to rename it, rewrite its brief, add or remove members and change who leads. The team keeps its conversation.

### Improvements

- **Teams no longer stop for approval at every step.** Each team now has its own Permissions setting, and new teams start on Bypass permissions so they can work unattended. Existing teams keep their current behaviour until you change it in Edit team.

## 0.1.53 — 2026-10-14

### New

- **Tabs in spreadsheets.** A spreadsheet can now hold several tabs, like Excel and Google Sheets. Add one with +, double-click to rename, drag to reorder, and right-click to duplicate or delete (with undo). Formulas can use other tabs, such as `=Sales!B2` or `=SUM('Q1 data'!A1:A9)`, and renaming a tab updates the formulas that use it. Excel export keeps every tab; CSV export lets you pick one. Your agents can work across tabs too.
- **Read long text in a cell.** Drag the bottom edge of a row number to make a row taller and its text wraps. Double-click the edge, or right-click → Fit row height to text, to size rows to their text. Long text now runs on into empty cells to the right instead of being cut off, and the formula bar's expand button (⌃⇧U) shows a cell's whole text.
- **Home greets you each morning.** The first time you come back after 6am, Muse opens on Home so your brief is the first thing you see.

### Improvements

- **Unsent messages are kept.** Text you've typed but not sent stays in each chat when you switch away or restart Muse, and long messages scroll instead of being hidden.
- **Card updates stay out of the way.** The agents that refresh dashboard and Home cards now close themselves when done and no longer fill up Chat or Home's conversation list. If an update fails, the card shows why.
- **Cleaner helper chats.** When a bot helps with a document, sheet or dashboard, its behind-the-scenes instructions no longer appear in your messages.

## 0.1.52 — 2026-10-13

### New

- **Make your dashboards your own.** Press Edit on any dashboard to drag cards into the order you want, make each card Small, Wide or Full width, and give it its own colour. Pick the dashboard's accent colour, how see-through its cards are (Frosted, Smoked or Solid) and its icon. Cards in a row now line up at the same height, so pages look tidy.
- **Ask an agent to arrange it.** Agents can now resize, recolour and reorder cards for you, e.g. “make the LinkedIn chart full width and the dashboard blue”.

## 0.1.51 — 2026-10-13

### New

- **Queue your next message.** While a bot or session is working, choose Add to queue or press Return. Messages run in order after the current work finishes. Remove a pending message at any time; Stop pauses the queue until you resume it. Saved queues reopen paused when you restart Muse.
- **A guided welcome.** New users get a step-by-step introduction to Muse, choose what they want help with and pick a starter agent. A skippable Home tour explains the main controls, with a Getting started checklist to help you find your way. Existing users can replay the welcome or take the tour from the Muse menu.

### Improvements

- **Choose the account for every automation.** Both automation editors now let you pick which AI account runs the task and show what the default account means.
- **Highfell for new spaces.** New workspaces open with the Highfell theme. Existing theme choices stay as they are.

## 0.1.50 — 2026-10-13

### Fixes

- **Home is back.** 0.1.49 opened on Chat and hid the Home tab. Muse now opens on Home again, with your daily brief, cards and to-dos, and Home sits beside Chat at the top of the window.

## 0.1.49 — 2026-10-13

### New

- **Home, your personal starting point.** Home now opens on a daily brief: today’s meetings, the to-dos and replies you owe, and updates worth knowing, shown only when there is something to say. Add your own to-dos and tick them off right there.
- **A morning brief from every account.** Choose who reads your calendar, inbox and tasks each morning. If you’re signed in to more than one AI account, Muse reads them all, labels each item with its account and shows a meeting once even when two calendars have it.
- **Spaces.** Keep Work, Personal or a side project as separate places, each with its own folder, chats, bots and memory. Agents only look across spaces when you allow it. Canvas has moved to Settings → Labs.
- **Home cards.** Ask an agent for a card (your follower count, top meetings, a weekly number) and it appears on Home. Agents can keep cards fresh on a schedule.
- **Dashboards.** Describe a dashboard and Muse builds it from cards, with a helper beside it to change it.
- **Documents, sheets and slides.** Write documents with suggested edits you accept or reject. Use spreadsheets that work like Excel and Google Sheets (type in cells, 81 formula functions, click cells to build formulas, fill, copy and paste). Make animated, website-quality presentations with themes or your brand, then present full screen with Esc, arrows, a remote or the keypad.
- **Open in Google or Office.** Export to Word, Excel and editable PowerPoint, or save a Google-ready copy and open Google Drive in one click. PDF and single-file web page exports too.
- **Helpers stay beside your work.** Asking for changes from a document or dashboard keeps the conversation in its side panel instead of jumping to Chat.
- **Automations.** A clearer Automations screen with a four-question setup: what to do, who does it, which AI account, when, and where results go (your brief, a Home card or a bot’s chat). Deleted automations can be undone.
- **Marketplace.** Browse and search apps your providers can connect to, see what’s already enabled for each account, and open the provider’s own setup.
- **Gmail shared across agents.** Connect Gmail once in Muse and use it from any local agent.
- **Your own cloud computer (preview).** Set up a personal Boat cloud host and send it tasks.

### Improvements

- Large pastes in Chat and Home become tidy collapsible chips.
- Images in agent replies are shown in the chat.
- Home and Chat share one look over your theme photo, with readable text on light and dark themes, and photos that always fill the window.
- New Inter typography, provider logos for sessions, calmer bot avatars and a polished ⌘K palette.

## 0.1.48 — 2026-10-02

### Fixes

- **Up-to-date models for each account.** Codex and Claude Code model pickers now ask the selected account’s installed provider for its available models, so switching accounts refreshes the choices.
- **Newer Codex desktop models appear in Muse.** Muse recognises the current Codex desktop launcher and prefers it over an older standalone CLI, including models such as GPT-6.1-Sol when available to your account.
- **Clearer signed-out model lists.** Accounts that are not signed in no longer show generic provider models as if they were available.

## 0.1.47 — 2026-10-01

### Fixes

- **Use your Mac login for bot helpers** — subagents now offer “This Mac’s login”
  alongside saved accounts, with the corresponding model choices. This explicitly
  uses the provider’s local login even when another account is your global default.
- **Keep the work panel specific to each conversation** — opening or closing the
  right-hand panel in one session, bot or team no longer changes it in the others.
  Returning to a conversation restores its choice during the current Chat session.
- **Use Playbooks in a narrow panel** — the editor adapts to the available width
  so its fields and buttons remain reachable.
- **Clearer playbook validation** — “Validate steps” now explains that it checks
  fields without running the task. Edited steps must be validated again, and changes
  clear outdated routine previews. Failed saves preserve the last valid playbook.
- **See the correct routine interval** — the routine editor now shows its saved
  interval instead of always displaying one hour.

## 0.1.46 — 2026-10-01

### Improvements

- **Choose your bot's account** — pick a saved Personal or Work account when creating
  a bot. Muse remembers the choice for its sessions and shows that account's model choices.
- **Give bots their own helpers** — in Manage agents, configure subagents with their
  own Codex or Claude Code provider, saved account, role and model. A Claude bot can
  delegate to Codex, or vice versa, using the subscription you selected for each helper.
- **Keep helper accounts predictable** — unavailable helper accounts produce an error
  instead of silently switching to another subscription, including when a helper resumes.

## 0.1.45 — 2026-09-30

### Improvements

- **Resize the browser and work panel** — hover over the left edge of the right-hand
  panel and drag to make it wider or narrower. Your chosen width is remembered when
  you reopen the panel or restart Muse, and works across its browser and other tabs.

## 0.1.44 — 2026-09-30

### Fixes

- **Refresh models when switching accounts** — session model pickers now refresh when
  your selected account or inherited account changes. You can also refresh the list manually.
- **Account-aware bot model choices** — new bots use the default account's catalog, and
  existing bot editors use the account assigned to that bot.
- **No misleading fallback lists** — failed account lookups no longer silently show the
  Mac's default catalog. Model discovery also avoids conflicting inherited credentials.

## 0.1.43 — 2026-09-29

### Fixes

- **More reliable account isolation** — signing in to a named provider account and
  launching its agents no longer inherit conflicting provider credentials from the
  shell that opened Muse. Credentials saved for the selected account still take priority.
- **Roomier account settings** — the Accounts pane has a consistent size, and the
  settings window provides enough width for its tabs.

## 0.1.42 — 2026-09-29

### Improvements

- **Sign in to each account from one click** — Log in now opens Terminal with the
  provider's own sign-in for that account (Claude Code, Codex, Grok, Kimi, OpenCode and
  Hermes), and Settings → Accounts updates to Signed in automatically when you finish.
- **See the right models for each account** — the model picker lists the models available
  to the account the agent runs on, so a personal account no longer shows your work plan's
  models. Codex, Grok, Kimi, Cursor and OpenCode read their catalogs per account.
- **Clearer account options** — each provider explains whether it uses its own login, an
  API key, or this Mac's existing login.
- **Memory that keeps up with you** — trusted agent memories are confirmed automatically,
  new work defaults to your workspace project, and agents recall relevant memory when you
  ask what was decided before.

### Fixes

- Log in no longer opens an invisible terminal on the canvas, and Claude Code, Kimi and
  Hermes now start their real login commands.

## 0.1.41 — 2026-09-29

### Improvements

- **Use more than one subscription** — add accounts such as Work and Personal in
  Settings → Accounts, then sign in to Claude Code, Codex, Grok, Kimi, OpenCode or Hermes
  separately for each one, or add an API key (including Cursor and the Muse harness).
  Muse never sees your provider logins; each provider signs in with its own login.
- **Choose the account per agent or per project** — every agent shows which account it
  runs on in its composer and canvas footer, and you can switch with one click. Projects
  can set a default account so work stays on work subscriptions.
- **Keep going when you hit a usage limit** — when an account reaches its limit, Muse
  offers to continue on another account or wait for the reset. Projects can choose to wait
  or switch automatically.
- **Your setup follows every account** — settings, skills and instructions are shared from
  your main login, and conversations carry a short recap when they move between accounts.

### Fixes

- Agents can no longer hand work to an agent on a different account without asking you.

## 0.1.40 — 2026-09-22

### Improvements

- **Organise conversations with optional projects** — bots and teams keep their ongoing
  chats, with a visible Working in indicator to select, correct or clear the active project.
- **Choose a project when starting a session** — select an existing project or create one
  before choosing your agent. Sessions also show their active project above the chat.
- **Create projects with optional source folders** — name a project and add folders from
  your Mac, or leave folders empty for research, writing and other work. Files stay in place.
- **Keep project context attached to work** — project memory and documents follow the
  assigned project. Changing the current selection preserves chat history and keeps
  running tasks and delegated work attached to their original project.

### Fixes

- Conversation summaries retain project attribution, including explicit labels where
  older history has no recorded project.
- Existing conversations retain their workspace association during migration.

## 0.1.39 — 2026-09-21

### Improvements

- **Message a Muse team from your phone** — experimental iMessage support connects
  your own Photon account to a selected team, with pairing and working feedback.
- **Complete website sign-in privately** — connected messaging sessions can send
  short-lived links for website access, login and approvals. Your Mac must stay online.
- **Try the Nightscreen theme** — painted backgrounds sit behind matte-glass surfaces,
  with clearer bot, team and session icons.
- **Smoother everyday navigation** — chat, tabs, lists and the command palette now use
  consistent motion, while palette rows stay still under the pointer.

### Fixes

- Conversation file and website links open in the chat work panel.
- Private sign-in links are fully tappable and avoid unrelated page links.
- Messaging recovery preserves review gates and keeps replies attached to their request.
- Running bots and teams are easier to spot in the sidebar.

## 0.1.38 — 2026-09-09

### Fixes

- **Approve native Codex tool requests from chat** — MCP permission choices now appear
  correctly, and waiting sessions no longer show Done because their terminal title animates.
- **Browser tools work with the preview closed** — agents can inspect, interact with,
  and capture browser pages without requiring you to keep their panel visible.
- **Builds tolerate iCloud-backed worktrees** — guarded builds freeze their source inputs
  before compilation and report low disk space before starting.
- **Old build caches are cleaned up automatically** — inactive task caches are now capped
  so accumulated builds do not fill your disk.
- **Background commands use Muse supervision** — resumed Claude runs receive explicit
  recovery instructions when native background-task options are unavailable.

## 0.1.37 — 2026-09-09

Keep Muse running reliably and long-running agent work under supervision.

### Fixes

- **Muse no longer crashes when your Mac's thermal state changes** — temperature
  notifications are now handled safely, preventing the unexpected quits seen during use.
- **Long-running agent work stays supervised** — headless Claude runs no longer start
  native background jobs that can disappear when a reply ends. Agents now use Muse-owned
  terminals for durable commands and wait for native subagents before finishing.

## 0.1.36 — 2026-09-08

Read complete answers and work with email drafts directly in your conversation.

### Improvements

- **Email drafts stay in chat** — view the full message, edit and save a local draft,
  copy it, or open it in your mail app.
- **Browse inbox results inline** — expand messages, filter unread items, and prepare
  reply drafts when an agent returns an inbox card.
- **Long answers remain visible** — complete replies, diagrams, tables, and cards no
  longer disappear behind an automatic “Full explanation” link.

### Fixes

- **Research Team documents open beside the conversation** — document links now open
  in the right work panel.
- **Delegated agents stay with their parent** — nested agents remain within the session
  that started them instead of appearing as separate top-level conversations.

## 0.1.35 — 2026-09-08

Follow subagents as they work, and let longer bot tasks finish at their own pace.

### Improvements

- **Watch delegated work in your conversation** — an expandable Agents panel shows each
  child's current activity, running and finished states, and failure details. Animated
  connections follow active work and respect Reduce Motion.
- **Delegate across your harnesses** — delegated execution is available across Muse's AI
  harnesses, with child activity shown where the provider exposes it.
- **Long bot tasks keep going** — quiet team turns are no longer stopped after five minutes
  of inactivity. Waiting on background work or a subagent does not count as completion,
  and you can still stop a run yourself.
- **Team chats open at the latest message** — reopening a team conversation starts at the
  bottom, with a fresh scroll position for each session.

## 0.1.34 — 2026-09-08

Keep separate conversations separate, even when they use the same workspace.

### Fixes

- **Sessions keep their own history** — Codex and Claude terminal-history recovery now reads
  only the session explicitly associated with that chat. A newer conversation in the same
  folder can no longer be adopted by another chat.
- **Reopened sessions retain their identity** — reopening a saved terminal session preserves
  its exact provider session ID through the return to chat.
- **Missing history stays isolated** — if a session cannot be identified, Muse leaves its
  history alone instead of guessing from nearby session files.

- **Team replies lay out more reliably** — rich team messages use a stable layout, avoiding
  repeated sizing work for tables and diagrams.

This update prevents new history mix-ups; it does not automatically separate conversations
that were already mixed in an earlier version.

## 0.1.33 — 2026-09-08

Codex conversations recover correctly after restarting Muse.

### Fixes

- **Your history returns after restart** — saved Codex conversations now load from both older
  and current session formats, including conversations spanning a Codex update.
- **Follow-ups keep their context** — switching a reopened Codex session back into chat retains
  its saved conversation instead of starting a fresh session.
- **Restored chats stay readable** — Muse context and internal instructions stay out of the
  visible conversation, and team-only replies remain separate from private chats.
- **Diagrams fit the conversation** — inline diagrams stay compact and scrolling continues
  naturally through the chat. Response details also stay within a stable layout.

## 0.1.32 — 2026-09-07

Clearer conversations, shared memory, more reliable bots and teams, and early iPhone companion support.

### Improvements

- **Visual answers stay useful** — diagrams and other visual explanations remain visible in chat,
  with supporting detail and follow-up exploration easier to reach.
- **Questions are easier to answer** — theme-aware question cards present clear choices and a
  custom-answer option when none of the suggestions fits.
- **Memory follows your work** — sessions and bots can use reviewed preferences and relevant
  project knowledge across agent providers. Each bot's private notes stay scoped to that bot.
- **Early iPhone companion support** — the Mac host supports pairing, saved conversations,
  bot messages, and shared team rooms for the companion test app. The companion has a Nightglass
  interface; iPhone distribution remains a separate test build, not part of this Mac download.

### Fixes

- **Bot messages reach the right place** — sending from mobile works even when the Mac is showing
  a different canvas. Failed sends keep the draft and a visible error instead of briefly flashing.
- **Saved conversations are available sooner** — mobile can load persisted history without
  waiting for general service startup.
- **Cloud memory cannot hold up a message** — startup no longer rebuilds every memory record,
  and automatic memory lookup skips files that still need downloading from iCloud.
- **Deleted bots stay deleted** — old sessions belonging to a deleted bot no longer appear in the
  mobile list, and deleting a session removes its stale channel entry. A deleted bot's name can
  be used again without reviving its old sessions.
- **The companion stays current** — the updated iPhone test app refreshes bots and sessions while
  open, closes conversations removed on the Mac, and supports both keyboard Send and the send button.
- **More reliable continuity** — agent sessions and team conversations retain their ownership and
  routing as work moves between surfaces.

## 0.1.31 — 2026-09-04

Team rooms recover from stuck agents and make every handoff visible.

### Fixes

- **Teams cannot spin forever** — if a team agent produces no activity for five minutes, Muse
  stops the wedged worker and unlocks the room so you can retry. If the agent already finished
  its answer but its provider failed to exit, Muse preserves and displays that answer first.
- **Handoffs are visible** — whenever one teammate passes work to another, the shared room now
  shows who received it and the exact task they were given, including their `@handle`.

## 0.1.30 — 2026-09-04

Bots get faces, replies lead with the answer, and the surface switch joins the window controls.

### Improvements

- **Bots have faces** — hiring a bot now starts by picking one of eight drawn faces. Each blinks
  on its own rhythm, scans while the bot is working, looks straight at you when it needs an
  answer, and closes its eyes when the bot goes offline.
- **A hire sheet that fits what it asks** — the sheet sizes to its content instead of a fixed
  slab, the avatar previews as you type, and Advanced collapses into a single row showing the
  harness, model, and permissions you are agreeing to.
- **Sessions say what they are about** — every session in the rail carries a one-line preview of
  the brief you opened it with, and shows the current step while it is working.
- **Chat and Canvas sit with the window controls** — the surface switch moved off the middle of
  the screen onto the traffic-light line beside the sidebar toggle. It no longer covers the
  conversation or your node cards, and it keeps one home whether the sidebar is open or closed.
- **You can see what an agent is doing** — a working agent shows its steps as it takes them, each
  ticked off with the command behind it, instead of a single spinner and a timer.
- **Answers lead with the answer** — a long reply keeps its opening statement in view and puts
  the rest behind one line, so a busy transcript stays readable.
- **Clearer questions** — when an agent asks you something, its options render as a card with
  numbered choices, or with checkboxes and a Next button when it can take several answers.

## 0.1.29 — 2026-09-04

The chat sidebar returns as a proper rail, and the window controls line up with it.

### Improvements

- **A rail you can navigate** — the chat sidebar now opens with a workspace switcher, a live
  search row, and separate bots, teams, and sessions groups that each collapse on their own.
- **Controls that stay put** — the sidebar toggle sits on the same line as the window buttons and
  keeps one fixed home instead of moving when you open or close the rail. It is now available on
  every chat surface, so collapsing the sidebar in Activity, Files, Widgets, or Routines no longer
  leaves you without a way to bring it back.
- **Even group controls** — the add buttons for bots, teams, and sessions are the same size and
  share one edge.
- **The session creator stays put** — starting a session, hiring a bot, or creating a team opens
  inside the window rather than spilling past its edge.
- **A calmer conversation** — the pinned environment card starts hidden; the toolbar button brings
  it back when you want it.

## 0.1.28 — 2026-09-03

Long-running commands now stay attached to the agent that started them.

### Improvements

- **Reliable background commands** — agents start long builds, tests, and servers in a
  Muse-supervised terminal instead of a provider-private background process that can disappear
  when the model finishes its turn.
- **Completion without polling** — the new `terminal.wait` tool waits on typed runtime events and
  returns the command's current state, exit code, and bounded output.
- **Every harness follows one protocol** — Claude Code, Codex, Cursor, Grok, Hermes, Kimi,
  OpenCode, and Muse Harness receive the same current background-job guidance on new and resumed
  turns.
- **Long waits stay connected** — Muse's MCP bridge now extends its control-socket deadline for
  event and terminal waits instead of cutting them off at the normal ten-second request timeout.

## 0.1.27 — 2026-09-02

Voice navigation now works the same way in Chat and Canvas.

### Improvements

- **Voice can see every session** — both conversational Talk and local Command receive the full
  bot, team, and one-off session roster across all canvases from the moment they start.
- **Open sessions by voice** — say “switch to Coder session” or “open Ada” to move directly to an
  existing conversation without sending it a new prompt.
- **Switch Chat lists hands-free** — “show my sessions,” “go to bots,” and similar phrases open the
  requested Chat sidebar immediately.
- **Shared voice tools** — cloud voice can list sessions, resolve uncertain names, open existing
  sessions, and switch between the Bots and Sessions lists through the same control plane.

## 0.1.26 — 2026-09-02

Claude Code's model picker now includes Fable 5.1 and a moving Fable alias.

### Fixes

- **Fable 5.1 is selectable** — Claude Code sessions and bots now expose the current
  `claude-fable-5-1` model.
- **Fable stays current** — the `fable` choice follows whichever Fable release the installed
  Claude Code account resolves as latest, matching the existing Sonnet, Opus, and Haiku aliases.
- **Muse Harness fallback updated** — direct Anthropic bots include Fable 5.1 even when the live
  models endpoint is temporarily unavailable.

## 0.1.25 — 2026-09-02

Model pickers now show the current models available through each configured harness and account.

### Improvements

- **Live model catalogs** — Codex, Cursor, Grok, Kimi, OpenCode, and direct model providers now
  populate the shared picker from their authenticated catalog, with safe offline fallbacks.
- **Latest Claude aliases** — Claude Code offers Sonnet, Opus, and Haiku aliases that follow the
  latest model available to the signed-in account.
- **Consistent bot setup** — hiring, creating, editing, and chatting with a bot now use the same
  model source and expose the same installed harness choices.
- **Current Codex reasoning controls** — Codex model variants now show their supported effort
  range, including `xhigh`, `max`, and `ultra` where available.

### Fixes

- **No duplicate OpenAI session entry** — the one-off session menu no longer displays the internal
  OpenAI API transport beside Codex. The owned transport remains available to durable bots as
  Muse Harness.

## 0.1.24 — 2026-09-02

Muse Harness now runs OpenAI, Claude, Grok, and Kimi models while Muse keeps control of each
bot's instructions, tools, and local conversation memory.

### Improvements

- **Four direct model providers** — choose OpenAI GPT, Anthropic Claude, xAI Grok, or Moonshot
  Kimi from the same Muse Harness model picker.
- **One conversation across models** — switch model vendors on the next turn without losing the
  bot's existing Muse-owned chat history.
- **Secure provider setup** — add or remove each provider's API key in the new Settings → Models
  screen; keys remain in Muse's secure credential store.
- **Provider-native agent loops** — Muse speaks each vendor's supported Responses, Messages, or
  Chat Completions protocol while keeping tool execution in Muse.

### Reliability

- **Authoritative instructions everywhere** — every direct provider receives the bot's current
  instructions in its real system channel on every turn.
- **Safe model switching** — incompatible reasoning settings are cleared automatically, and old
  OpenAI response identifiers are never forwarded to another vendor.

## 0.1.23 — 2026-09-02

Muse now owns the system prompt and conversational memory for direct OpenAI bots.

### Improvements

- **Muse-owned agent sessions** — direct OpenAI bots now use a stable Muse session rather than
  treating a provider response ID as the conversation. Their recent user and assistant history is
  stored locally and privately on this Mac.
- **Instructions refresh without forgetting the conversation** — editing a bot's system prompt
  takes effect on its next turn while its previous chat remains available.
- **Provider-neutral harness foundation** — Muse now owns the model loop, tool execution, session
  limits, and events behind a backend interface designed for additional model providers.
- **Clearer runtime choice** — the bot editor now labels this path “Muse Harness · OpenAI” and
  explains which responsibilities stay with Muse.

### Reliability

- **Private bounded transcripts** — local harness sessions use user-only file permissions and
  bounded history so conversations cannot grow without limit.
- **Smooth session migration** — conversations started by the previous direct OpenAI runtime
  migrate to stable Muse session IDs on their next turn.

## 0.1.22 — 2026-09-02

Muse makes saved bot instructions authoritative on every desktop conversation turn.

### Improvements

- **True system-prompt bots** — choose OpenAI API as a custom bot's harness to send its private
  instructions as an actual system message, with resumable conversations and Muse tool access.

### Fixes

- **Codex follows edited bot instructions** — fresh and resumed Codex turns now receive the
  current saved instructions instead of relying on stale session context.
- **First messages receive their full brief** — startup now installs the memory and profile
  bootstrap before agents can launch, removing a race that could omit a bot's role.
- **Correct GPT-5.6 reasoning controls** — the direct OpenAI harness offers the effort levels the
  Responses API accepts, preventing a selectable `minimal` setting from failing a turn.

## 0.1.21 — 2026-09-02

Muse makes saved bot instructions authoritative on every desktop conversation turn.

### Improvements

- **True system-prompt bots** — choose OpenAI API as a custom bot's harness to send its private
  instructions as an actual system message, with resumable conversations and Muse tool access.

### Fixes

- **Codex follows edited bot instructions** — fresh and resumed Codex turns now receive the
  current saved instructions instead of relying on stale session context.
- **First messages receive their full brief** — startup now installs the memory and profile
  bootstrap before agents can launch, removing a race that could omit a bot's role.

## 0.1.20 — 2026-09-02

Muse restores reliable conversations for desktop sessions and saved bots.

### Fixes

- **Sessions and bots respond again** — agent activity and transcript updates now remain connected
  even if another part of Muse's startup encounters a problem, preventing conversations from
  becoming stuck on Starting.
- **Send failures stay visible** — a message that cannot be delivered now leaves a clear failure
  in the conversation or session instead of disappearing without explanation.

## 0.1.19 — 2026-09-01

Muse makes first launch fit comfortably on laptop displays and prepares the Mac for secure,
subscription-aware remote access without moving local work into the cloud.

### Improvements

- **A first-run screen that fits** — onboarding now keeps its privacy confirmation and Enter
  workspace action visible while the detailed readiness checks scroll independently.
- **Clear local and cloud voice boundaries** — the setup flow distinguishes private on-device
  Command and Dictate from optional cloud Talk before you enter the workspace.
- **Remote-ready Mac host** — Muse now includes the authenticated pairing, scoped approvals,
  attachment, health, and entitlement foundations required by the separate mobile client.

### Reliability

- **Hardened desktop packaging** — production builds verify required resources, helper tools,
  signatures, archive integrity, and update metadata before publication.

## 0.1.18 — 2026-08-26

Muse brings voice controls into Chat and takes you straight into every new session you start.

### Improvements

- **Voice controls in Chat** — start a conversation, give a local command, dictate verbatim, switch
  operating modes, or open voice settings directly from the Chat sidebar.
- **New sessions open immediately** — choosing a provider from either new-session menu now creates,
  selects, and focuses that conversation as soon as the agent is ready.

## 0.1.17 — 2026-08-26

Muse now cleans up agent processes reliably when the app closes, preventing abandoned sessions
from continuing to consume CPU in the background.

### Reliability

- **No orphaned agent processes** — quitting or crashing Muse now terminates the complete process
  group for each Codex, Grok, or other terminal-backed agent, including stubborn child processes
  that need a forced shutdown.
- **Accurate session activity** — the lifecycle monitor runs independently from the provider process,
  so it cannot make an otherwise idle terminal session appear busy.

## 0.1.16 — 2026-08-19

Muse makes starting Chat sessions reliable and keeps browser work attached to the conversation
that opened it.

### Improvements

- **Stable new-session picker** — the Chat `+` button now opens a persistent provider picker, so
  you can choose a new agent without a nested menu collapsing while you move through it.
- **Browsers belong to their chat** — when an agent opens a website from Chat, Muse presents it in
  that conversation's right-hand work panel and reuses it for later tabs.

### Reliability

- **Conversation-safe browser sessions** — each agent keeps its own browser surface, browser-to-chat
  associations survive restarts, and background agents no longer take over the browser in the chat
  you are currently reading.
- **Reliable agent creation sheets** — moving from the agent manager into the custom-agent creator
  now waits for the first sheet to close cleanly instead of briefly opening and disappearing.

## 0.1.15 — 2026-08-19

Muse makes the conversation workspace clearer and lets you browse one-off sessions across canvases
without losing your place.

### Improvements

- **Clear Chat layout** — the conversation-first layout is now called Chat, with distinct Sessions
  and Bots tabs that make one-off agents easy to tell apart from saved teammates and teams.
- **Canvas-scoped sessions** — filter Sessions by canvas and open any matching conversation while
  staying in Chat; browsing sessions no longer switches the active canvas or changes its layout.
- **Honest session status** — session rows now show Starting, Working, Done, Needs you, Failed,
  Idle, or Stopped instead of displaying a permanent green activity dot.

### Fixes

- **Close sessions from Chat** — selected or hovered session rows expose a direct close control,
  including sessions that belong to a different canvas.

## 0.1.14 — 2026-08-19

Muse now has a collaborative Bots workspace where saved agents can work together in durable,
voice-controlled team rooms with shared project knowledge and private bot memory.

### New

- **Bots workspace** — create and manage saved bots and teams, talk to one bot or an entire team
  with keyboard-friendly `@` mentions and `@channel`, and keep each room's conversation isolated.
- **Real team handoffs** — teammates can plan, review, delegate, and return work in one bounded
  workflow, with clearly attributed replies and safeguards against duplicate or endless messages.
- **Voice control in Bots mode** — find bots and teams, open their rooms, start fresh sessions, and
  direct work using the same full voice controls available elsewhere in Muse.
- **Project and bot memory** — Project Brain provides durable shared context while each bot keeps
  profile-isolated memory, working notes, and citations across sessions.
- **Routines and webhooks** — create scheduled or webhook-driven automations with approval gates,
  execution history, and a bundled local hook service.

### Improvements

- **Readable team chat** — Markdown rendering, inline mention chips, distinct bot identities, and
  edit/delete controls for both teams and bots make active rooms easier to follow and manage.
- **Long-running sessions** — fresh-session and context-compaction support keeps established team
  rooms useful without carrying unlimited transcript history into every new task.
- **Visual polish** — Nightglass and Glasswing themes add richer translucent surfaces, and the
  tool catalogue now includes recognizable provider and plugin artwork.

### Reliability

- **Rock-solid memory startup** — transient Project Brain index contention now waits safely and
  can no longer silently remove memory tools from a running workspace.
- **Bounded collaboration** — courtesy replies do not retrigger teammates, handoffs have hop
  limits, and high-volume transcripts update the UI at a controlled cadence.

## 0.1.13 — 2026-08-13

Muse no longer quits on launch after Download & Restart, and remote Hermes agents can exchange
files with the local Muse workspace without requiring the Hermes Desktop app.

### New

- **Remote Hermes files** — images attached in Muse are uploaded securely to the remote Hermes
  session, while files generated by Hermes are downloaded into the workspace and open normally
  from the conversation.

### Fixes

- **Launch after update** — provider logos and other bundled art now load from
  `Contents/Resources` instead of a SwiftPM path that only exists on the build machine.

## 0.1.12 — 2026-08-13

Muse widgets can now combine fully custom HTML designs with reliable scheduled live data.

### New

- **Custom live widgets** — design widget cards with your own HTML, CSS, SVG, and JavaScript while
  keeping Muse's background schedules and refresh controls.
- **Live data bridge** — scheduled JSON data is available to custom widgets immediately and emits
  an update event whenever new data arrives, enabling branded goals, progress bars, and dashboards.

### Compatibility

- **Existing widgets stay intact** — legacy custom widget state remains separate from scheduled
  data, so current HTML widgets continue to load without migration.

## 0.1.11 — 2026-08-13

You can now launch Grok agents on the canvas and run command-palette actions entirely from the keyboard.

### New

- **Grok agents** — add a Grok node the same way as Claude Code or Codex. Muse uses your existing
  `grok` login, maps plan / workspace / bypass permissions, and streams the conversation in chat.
- **Keyboard command palette** — press ⌘F, type to filter, use ↑/↓ to move, and Enter to run.
  Searching for a new agent no longer requires the mouse.

### Fixes

- **Composer focus** — newly opened agent chats take keyboard focus after the launch sheet closes,
  so the first keystrokes go into the prompt instead of nowhere.

## 0.1.10 — 2026-08-13

Muse agent development is now isolated and self-cleaning, preventing parallel coding tasks from
interfering with one another or leaving package operations stuck in the background.

### Reliability

- **Isolated coding tasks** — each agent task now gets an explicit worktree, branch, and SwiftPM
  build area so concurrent work cannot overwrite another task or share a wedged cache.
- **Bounded package operations** — Swift builds use locked dependencies, concurrency guards, logs,
  and full child-process cleanup when a task is cancelled or times out.
- **Safe workspace cleanup** — finished worktrees are checked for uncommitted changes and archived
  before removal, while orphan diagnostics target only confirmed Muse processes.


## 0.1.9 — 2026-08-12

Muse opens cited files correctly in split view and reliably completes update restarts.

### Fixes

- **Working split-view references** — file links ending in a line or column reference, such as
  `Plan.md:31` or `SpatialCanvas.swift:1026:14`, now open the actual local file.
- **Reliable Download & Restart** — update shutdown has bounded cleanup and installer fallbacks,
  preventing a stuck agent process from leaving Muse waiting for a manual quit.
- **Prompt update discovery** — update checks bypass local and edge caches so newly published
  releases appear as soon as the signed feed is deployed.

## 0.1.8 — 2026-08-12

Muse restores its branded app icon and makes update installation visibly responsive.

### Fixes

- **Branded app icon** — production packages now include the black-and-lime Muse cairn instead of
  falling back to macOS's generic application icon.
- **Visible update progress** — Download & Restart now reports download percentage, preparation,
  and restart stages, and surfaces stalled network requests as retryable errors.

## 0.1.7 — 2026-08-12

This maintenance release rolls the latest Stage-mode artifact previews, delegated-agent
visibility, safe turn reverts, and isolated Codex sessions into one current production build.

### Improvements

- **Current production package** — installs the latest completed Muse fixes from the production
  branch as a single update.

## 0.1.6 — 2026-08-12

Muse now keeps each Codex agent and its in-progress message isolated from every other conversation.

### Fixes

- **Independent Codex sessions** — Codex agents launched inside Muse no longer inherit a parent
  Codex task identifier, preventing prompts and attachments from appearing in another task.
- **Stable Stage-mode drafts** — switching between agents in Stage mode preserves each agent's
  composer draft and pending image attachments with the agent that owns them.

## 0.1.5 — 2026-08-12

Muse now makes delegated agent work visible and lets you safely undo a completed coding turn.

### New

- **Native subagent inspector** — delegated Codex and Claude runs now show their child agents,
  current activity, completion state, model, elapsed time, tool count, and token usage when the
  provider reports it.
- **Safe turn revert** — restore the exact workspace checkpoint from before an agent's last turn.
  Muse refuses the revert when later edits exist, so newer user or agent work is never overwritten.

### Improvements

- **Canonical child-run telemetry** — provider-specific Codex and Claude events now feed one
  consistent nested-run model, while missing provider details remain visibly unavailable rather
  than being guessed.

## 0.1.4 — 2026-08-12

Muse now keeps plans, files, and code reviews beside the conversation that created them.

### Improvements

- **In-context artifact previews** — click a local Markdown plan or code-file link to open it in a
  side panel inside the agent node instead of creating a browser node.
- **Native code review** — click Review or an individual changed file to inspect the last turn's
  diff alongside the conversation.
- **Automatic stage layout** — opening a file or review enters Stage mode automatically, giving the
  conversation and artifact enough room while web links continue to open in browser nodes.

## 0.1.3 — 2026-08-11

Muse now runs your own widgets on the canvas, lets you save the agents you use most, and remembers
what turned out to matter instead of everything that happened.

### New

- **Custom widgets** — build and install small apps that live on the canvas as cards. Open, close,
  and manage them from the command palette or the widget manager; a closed widget stays installed
  and searchable, and reopens on the canvas you are working on.
- **Custom agents** — save the agents you use often with their own name, role, provider, and
  permissions, then launch them straight from the command palette or the agent manager.

### Improvements

- **Clearer agent cards** — each card shows a stable summary of what its agent is actually working
  on, instead of a title that changes part-way through a turn.
- **Memory that improves with use** — the Project Brain keeps greetings and one-word replies out of
  its log, ranks what it recalls by how useful those records have proved, and writes a handoff note
  when one agent picks up another's result. Records marked unhelpful sink out of results without
  being deleted, and the brain asks to promote what it has learned once notes pile up.

## 0.1.2 — 2026-08-11

Muse voice input works reliably again, and rapidly updating conversations no longer freeze when
their text changes.

### Fixes

- **Reliable voice input** — normal listening and push-to-talk now always deliver microphone audio
  while preserving microphone privacy, echo protection, and interruption handling.
- **Stable live conversations** — chat messages, streamed Markdown, and the voice trace no longer
  trigger macOS selectable-text layout loops during rapid updates.
- **Copy without layout cost** — prompts, responses, code blocks, and voice-trace details retain
  explicit Copy actions without attaching expensive selection overlays to every live row.
- **Regression protection** — automated checks now prevent unsafe selection overlays from returning
  to the dynamic chat and voice-trace rendering boundaries.

## 0.1.1 — 2026-08-11

Muse now stays responsive through long agent turns, large conversations, and background use.

### Improvements

- **Reliable chat rendering** — conversations render in bounded, stable pages so long histories
  and rapid agent updates cannot repeatedly rebuild the whole workspace.
- **Smooth working feedback** — the animated thinking orb and status pulse now run independently
  from chat layout, preserving their motion without consuming the main thread.
- **Lower CPU and memory use** — hidden browser tabs, covered windows, offscreen canvas nodes,
  media, and decorative backgrounds suspend work when they are not visible.
- **Faster streaming and terminals** — high-frequency output is batched per agent while terminal
  bytes continue to render incrementally.
- **Freeze regression protection** — automated stress checks now cover large transcripts, bursty
  output, and accidental frame-driven animation inside the chat layout.

## 0.1.0 — 2026-08-10

First public alpha of Muse — a native macOS spatial canvas for running local AI agents.

### Highlights

- **Spatial canvas** — a persistent, zoomable world where every agent, note, browser tab,
  and terminal lives as a node you can arrange freely.
- **Local agent supervision** — launch Claude Code, Codex, and other CLI agents in
  PTY-backed nodes with restartable, named sessions.
- **Embedded browser** — WebKit browser nodes that agents can inspect, click, type in, and
  screenshot.
- **Markdown workflows** — file-backed notes with wiki links, shared documents, and a
  project brain agents can search.
- **Voice** — opt-in realtime voice control with a session-only conversation trace.
- **Automatic updates** — Muse now checks for new versions, shows the changelog, and can
  download and restart in place.
