# Personal fork

This fork includes Codex's compressed `.jsonl.zst` session history in local spend estimates
([upstream issue #1388](https://github.com/robinebers/openusage/issues/1388)).

Run **Actions → Build personal fork → Run workflow** on the desired branch. The macOS runner
tests the source and builds a self-contained app. Download the **OpenUsage-fork** artifact,
extract its ZIP, quit OpenUsage, and open the included app. Building locally requires full Xcode:

```sh
BUNDLE_ID=com.robinebers.openusage script/build_and_run.sh run
```

The fork uses the installed app's settings domain and local history. It is ad-hoc signed rather
than notarized; macOS can require approval in Privacy & Security, and Keychain may ask for access
again. It has no Sparkle update feed, so an upstream update cannot overwrite the fix.
Keep the original app until the fork works on your Mac.

The bundled Zstandard library is pinned in `Package.resolved`; no Homebrew decoder is needed.
The original logs remain untouched. See [Codex](providers/codex.md) for deduplication and account rules.
