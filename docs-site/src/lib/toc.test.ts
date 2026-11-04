// Unit tests for the table of contents. Run with `pnpm test`.

import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { stepNumbers, tableOfContents } from './toc.ts';

describe('stepNumbers', () => {
  it('keeps positive whole step numbers', () => {
    assert.deepEqual([...stepNumbers({ 'step-1-enable': 1, '2-install': 2 })], [
      ['step-1-enable', 1],
      ['2-install', 2],
    ]);
  });

  it('ignores anything that is not a step map', () => {
    for (const value of [undefined, null, 'steps', [1, 2], 3]) assert.equal(stepNumbers(value).size, 0);
    assert.deepEqual([...stepNumbers({ a: '1', b: 0, c: 1.5, d: 2 })], [['d', 2]]);
  });
});

describe('tableOfContents', () => {
  const headings = [
    { depth: 1, slug: 'title', text: 'Title' },
    { depth: 2, slug: 'before-you-start', text: 'Before You Start' },
    { depth: 2, slug: 'step-1-enable-remote-login', text: 'Step 1: Enable Remote Login' },
    { depth: 3, slug: 'check-it', text: 'Check it' },
    { depth: 2, slug: '2-install-herdr', text: '2. Install herdr' },
    { depth: 2, slug: 'phase-3-test', text: 'Phase 3: Test' },
  ];

  it('lists the headings below the title', () => {
    assert.deepEqual(tableOfContents(headings).map((item) => [item.depth, item.url, item.title]), [
      [2, '#before-you-start', 'Before You Start'],
      [2, '#step-1-enable-remote-login', 'Step 1: Enable Remote Login'],
      [3, '#check-it', 'Check it'],
      [2, '#2-install-herdr', '2. Install herdr'],
      [2, '#phase-3-test', 'Phase 3: Test'],
    ]);
  });

  it('numbers step headings in circles instead of in their titles', () => {
    const steps = stepNumbers({ 'step-1-enable-remote-login': 1, '2-install-herdr': 2, 'phase-3-test': 3 });
    const items = tableOfContents(headings, steps);
    assert.deepEqual(items.map((item) => [item.title, item._step]), [
      ['Before You Start', undefined],
      ['Enable Remote Login', 1],
      ['Check it', undefined],
      ['Install herdr', 2],
      ['Test', 3],
    ]);
  });

  it('keeps the title of a step heading without a number prefix', () => {
    const [item] = tableOfContents([{ depth: 2, slug: 'setup', text: 'Setup' }], new Map([['setup', 1]]));
    assert.deepEqual(item, { depth: 2, url: '#setup', title: 'Setup', _step: 1 });
  });

  it('strips Chinese step and phase prefixes when numbering TOC circles', () => {
    const zhHeadings = [
      { depth: 2, slug: '步骤-1开启远程登录', text: '步骤 1：开启远程登录' },
      { depth: 2, slug: '阶段-2迁移', text: '阶段 2：迁移' },
      { depth: 2, slug: '3-安装-herdr', text: '3. 安装 herdr' },
    ];
    const steps = stepNumbers({ '步骤-1开启远程登录': 1, '阶段-2迁移': 2, '3-安装-herdr': 3 });
    assert.deepEqual(tableOfContents(zhHeadings, steps).map((item) => [item.title, item._step]), [
      ['开启远程登录', 1],
      ['迁移', 2],
      ['安装 herdr', 3],
    ]);
  });
});
