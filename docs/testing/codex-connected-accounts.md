# Codex connections for Desktop users

## Automated coverage

`CodexConnectedAccountsTests` covers independent account storage, duplicate connections, private
file permissions, identity checks on reconnect, invalid credentials, discovery after the Desktop
login disappears, accepted sign-in URLs, helper communication, browser failure, and cancellation.

On a Mac with full Xcode selected, run:

```sh
swift test --filter 'Codex(ConnectedAccounts|HomeDiscovery|MultiAccountAssembly|WritableHomeRefresh|SwapAccount)Tests'
```

## Local verification on October 21, 2026

The full project test build stopped in the existing KeyboardShortcuts dependency because this Mac
has Command Line Tools without Xcode's SwiftUI macro plugins. The installed app was not replaced
or restarted.

An isolated temporary Swift package compiled the new connection service, store, settings view,
and home discovery. It reused the project's actual identity parsing and private file-writing code;
unrelated app dependencies, logging, and view styling used stand-ins. All seven new tests passed
(the helper test also ran both browser-success and browser-failure cases).

A separate probe exercised the new login service against the executable inside the installed Codex
Desktop (`0.150.0-alpha.8`). Using an empty private temporary home, it completed initialization and
received the browser login URL. The probe then stopped before opening the browser or authenticating.
It passed with the local callback port allowed. No existing login was read or changed.

This proves the isolated connection flow and local helper integration, not a complete app build or
authenticated multi-account operation.

## Remaining manual checks

1. Build and launch the complete app using `script/build_and_run.sh` on a Mac with full Xcode.
2. In Settings, add two different accounts and restart OpenUsage. Check that both cards show the
   correct live limits.
3. Switch accounts through Codex Desktop's logout/login flow. Refresh OpenUsage and check that both
   cards continue updating.
4. Reconnect a saved connection. A different account must be rejected without changing that connection.
5. Disconnect a connection and restart. Check that the Desktop login still works; the card can remain
   if another supported login source for the same account is still available.
6. Verify that a connected account's token renews and that the updated credential persists after restart.
