---
name: testflight-beta
description: Release a processed TestFlight build to external testers. Drafts its What to Test notes, English then Chinese, from CHANGELOG for the maintainer to approve, then adds the build to the Public Beta group and submits it for Beta App Review. Use when a build from `make testflight` has reached TestFlight, or when asked for a build's update notes, 更新日志, What to Test or Public Beta.
---

# TestFlight external testing

Testers in the external group get a build only after it joins the group and
passes Beta App Review. They read its What to Test, so the notes cover every
change since the build they have now. Commands and credentials are documented in
[releasing.md](../../../docs/guides/releasing.md#external-testing).

## 1. Pick the build

Use the tag the maintainer names. Otherwise use the newest
`git ls-remote --tags origin 'refs/tags/builds/*'` tag. `make release-status TAG=…`
must show `"state": "valid"`. If it doesn't, report the state and stop: CI is
still uploading, or the run needs `make testflight-retry`.

## 2. Collect the entries

Run `make testflight-notes TAG=…`. It prints the changelog entries that are new
since the build the Public Beta group has now. If it asks for `SINCE`, ask the
maintainer which build the testers last received.

## 3. Write the notes

Turn every entry into tester notes, or drop it on purpose. Drop only entries
that change nothing in the app, such as the website, docs site or CI.

- The sections are New, Improved and Fixed (新增, 改进, 修复), from Added,
  Changed and Fixed. Leave out a section that has no lines.
- Give each thing a tester can try its own line. Split a long entry into one
  line per action or behaviour.
- Lead with what to do and where: "tap + then Paste Image".
- Write each control's name in English, exactly as the app shows it, in both
  languages. Check every name against the strings in `Sources/`, because
  CHANGELOG sometimes paraphrases them.
- Keep any "Update the Heeler plugin to X on the Host" requirement.
- Use plain text with `- ` bullets and a blank line between sections. Write
  the English, then the Chinese, in one text under 4000 characters: Test
  Information has only `en-US`, so every tester reads both.
- Write the Chinese as natural Simplified Chinese. Translate tap as 轻点, touch
  and hold as 长按, and Composer as 输入框.

An approved build's notes, abridged, are the reference:

```text
New
- Paste an image into a message: tap + then Paste Image, or paste straight into the Composer.
- Chat shows images that Agents read or create as thumbnails. Tap one to zoom.
- Touch and hold an Agent on a By Workspace card to start a New Agent in the same Workspace and folder.
- Browse Directories hides dot folders. Tap the eye button to show them.

Improved
- The Shell Terminal input row moves in step with the keyboard.
- While Chat waits for a conversation, Show Agent Terminal and Check Again sit side by side, and Check Again shows a spinner.

Fixed
- Codex's folder access prompt now appears in Chat as a card with Trust and continue and Quit.
- iPhone Duo: Back, Show Chat / Show Agent Terminal and More now sit in the side controls.

新增
- 在消息里粘贴图片：轻点 + 再选 Paste Image，或直接粘贴到输入框。
- Chat 会以缩略图显示 Agent 读取或生成的图片，轻点可放大查看。
- 在 By Workspace 卡片上长按某个 Agent，可在同一 Workspace 和目录下新建 Agent。
- Browse Directories 默认隐藏以点开头的文件夹，轻点眼睛按钮可显示。

改进
- Shell Terminal 的输入行跟随键盘同步升降。
- Chat 等待对话时，Show Agent Terminal 和 Check Again 并排显示，Check Again 会显示加载动画。

修复
- Codex 的文件夹访问提示现在会在 Chat 中显示为卡片，提供 Trust and continue 和 Quit。
- iPhone Duo：Back、Show Chat / Show Agent Terminal 和 More 移到了侧边系统控件中。
```

## 4. Get approval

Save the notes as a text file in the scratchpad, outside the repository.
Show them in your reply and wait. The
maintainer tests the build before releasing it. Publish only after they approve
the notes in their own words, and apply their edits to the file first.

## 5. Publish

Run `make testflight-beta TAG=… NOTES=<file> DRY_RUN=1` and check its plan. Then
run it again with `YES=1`. The script reads the Team API key from the Keychain
itself. If that item is missing, give the maintainer the setup commands from
releasing.md to run with `!`. Report the final line, the build's group and
review state, to the maintainer.
