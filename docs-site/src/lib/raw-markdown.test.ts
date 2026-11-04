// Unit tests for the Markdown served next to each guide page. Run with `pnpm test`.

import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { absoluteGuideHref, toRawMarkdown } from './raw-markdown.ts';

const repo = 'https://github.com/ZingerLittleBee/Heeler';
const site = 'https://docs.heeler.bybee.dev';
const options = {
  sourcePath: 'docs/guides/tailscale.md',
  site,
  isDirectory: (path: string) => path === 'docs/adr',
};
const raw = (markdown: string) => toRawMarkdown(markdown, options);

describe('absoluteGuideHref', () => {
  it('turns site routes and images into absolute site URLs', () => {
    assert.equal(absoluteGuideHref('overlay-networks.md#prepare-the-host', options), `${site}/overlay-networks#prepare-the-host`);
    assert.equal(absoluteGuideHref('images/tailscale/form.png', options), `${site}/images/tailscale/form.png`);
  });

  it('keeps GitHub URLs, absolute URLs, and anchors', () => {
    assert.equal(absoluteGuideHref('../adr', options), `${repo}/tree/main/docs/adr`);
    assert.equal(absoluteGuideHref('https://herdr.dev', options), undefined);
    assert.equal(absoluteGuideHref('#troubleshooting', options), undefined);
  });
});

describe('toRawMarkdown', () => {
  it('returns a guide without relative links unchanged', () => {
    const markdown = '# Title\n\n* item one\n* item two\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n```sh\nrun --this\n```\n';
    assert.equal(raw(markdown), markdown);
  });

  it('rewrites only link destinations, keeping text and titles', () => {
    assert.equal(
      raw('See [**Prepare** the Host](overlay-networks.md#prepare-the-host "Prep") and [ADRs](../adr).\n'),
      `See [**Prepare** the Host](${site}/overlay-networks#prepare-the-host "Prep") and [ADRs](${repo}/tree/main/docs/adr).\n`,
    );
  });

  it('leaves absolute links, autolinks, and anchors alone', () => {
    const markdown = 'Read [herdr](https://herdr.dev), <https://example.com>, and [below](#steps).\n';
    assert.equal(raw(markdown), markdown);
  });

  it('does not touch link-like text in code', () => {
    const markdown = 'Run `[x](zerotier.md)`:\n\n```powershell\nWrite-Host ](Read-Host "x")\n[x](zerotier.md)\n```\n';
    assert.equal(raw(markdown), markdown);
  });

  it('rewrites reference definitions and images', () => {
    assert.equal(
      raw('Use the [setup guide][setup].\n\n![The form](<images/a b.png>)\n\n[setup]: vps-jump-host-setup.md "Setup"\n'),
      `Use the [setup guide][setup].\n\n![The form](${site}/images/a%20b.png)\n\n[setup]: ${site}/vps-jump-host-setup "Setup"\n`,
    );
  });

  it('rewrites href and src in raw HTML', () => {
    assert.equal(
      raw('<a href="images/a.png"><img src="images/a.png" width="300" alt="A"></a>\n'),
      `<a href="${site}/images/a.png"><img src="${site}/images/a.png" width="300" alt="A"></a>\n`,
    );
  });

  it('rewrites links inside tables and nested emphasis', () => {
    assert.equal(
      raw('| Guide | Notes |\n| --- | --- |\n| [ZeroTier](zerotier.md) | _see [EasyTier](easytier.md)_ |\n'),
      `| Guide | Notes |\n| --- | --- |\n| [ZeroTier](${site}/zerotier) | _see [EasyTier](${site}/easytier)_ |\n`,
    );
  });
});
